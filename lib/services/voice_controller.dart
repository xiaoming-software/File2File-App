import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/chat_models.dart';
import 'chat_controller.dart';
import 'voice_audio_engine.dart';
import 'voice_protocol.dart';
import 'webrpc_service.dart';

enum VoicePhase { idle, outgoing, incoming, active }

class VoiceUiState {
  const VoiceUiState({
    this.phase = VoicePhase.idle,
    this.chatSessionLocalId = '',
    this.chatRpcId = 0,
    this.voiceRpcId = 0,
    this.callId = '',
    this.peerToken = '',
    this.muted = false,
    this.startedAt,
    this.error = '',
  });

  final VoicePhase phase;
  final String chatSessionLocalId;
  final int chatRpcId;
  final int voiceRpcId;
  final String callId;
  final String peerToken;
  final bool muted;
  final DateTime? startedAt;
  final String error;

  static const idle = VoiceUiState();

  VoiceUiState copyWith({
    VoicePhase? phase,
    String? chatSessionLocalId,
    int? chatRpcId,
    int? voiceRpcId,
    String? callId,
    String? peerToken,
    bool? muted,
    DateTime? startedAt,
    String? error,
    bool clearStartedAt = false,
    bool clearError = false,
  }) {
    return VoiceUiState(
      phase: phase ?? this.phase,
      chatSessionLocalId: chatSessionLocalId ?? this.chatSessionLocalId,
      chatRpcId: chatRpcId ?? this.chatRpcId,
      voiceRpcId: voiceRpcId ?? this.voiceRpcId,
      callId: callId ?? this.callId,
      peerToken: peerToken ?? this.peerToken,
      muted: muted ?? this.muted,
      startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
      error: clearError ? '' : (error ?? this.error),
    );
  }
}

/// Desktop-compatible 1:1 voice call (type 6 / 11 + Opus binary).
class VoiceController extends ChangeNotifier {
  VoiceController({
    required WebrpcService webrpc,
    required ChatController chat,
  })  : _webrpc = webrpc,
        _chat = chat;

  final WebrpcService _webrpc;
  final ChatController _chat;
  final VoiceAudioEngine _audio = VoiceAudioEngine();

  VoiceUiState _state = VoiceUiState.idle;
  VoiceUiState get state => _state;

  bool _isInviter = false;
  String _peerPass = '';
  Timer? _ringTimer;
  final Set<int> _knownMediaSessions = {};

  bool get isBusy => _state.phase != VoicePhase.idle;

  /// Secondary OpenSession hello (voice) must not rebind the chat session.
  bool shouldSkipChatHello(int rpcId, String peerToken) {
    if (_knownMediaSessions.contains(rpcId)) return true;
    if (_state.voiceRpcId != 0 && _state.voiceRpcId == rpcId) return true;
    final existing = _chat.sessionByPeer(peerToken);
    if (existing != null &&
        existing.connected &&
        existing.rpcSessionId != 0 &&
        existing.rpcSessionId != rpcId) {
      _knownMediaSessions.add(rpcId);
      return true;
    }
    return false;
  }

  void onInboundSecondarySession(int rpcId, ChatSession chatSession) {
    _knownMediaSessions.add(rpcId);
    if (_state.phase != VoicePhase.idle &&
        chatSession.peerToken == _state.peerToken &&
        !_isInviter &&
        _state.voiceRpcId == 0) {
      // type11 may arrive later; keep candidate id if matches later.
    }
  }

  Future<void> invite(ChatSession session) async {
    if (!_webrpc.isOnline) {
      throw StateError('请先登录');
    }
    if (!session.connected || session.rpcSessionId == 0) {
      throw StateError('请先连接会话再发起语音通话');
    }
    if (isBusy) {
      throw StateError('当前已有语音通话，请先结束');
    }
    final pass = session.peerPass.trim();
    if (pass.isEmpty) {
      throw StateError('缺少对方口令，请重新连接聊天会话后再试');
    }
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      throw StateError('需要麦克风权限才能发起语音通话');
    }

    final callId = '${session.rpcSessionId}-${DateTime.now().millisecondsSinceEpoch}';
    _isInviter = true;
    _peerPass = pass;
    _setState(
      VoiceUiState(
        phase: VoicePhase.outgoing,
        chatSessionLocalId: session.id,
        chatRpcId: session.rpcSessionId,
        callId: callId,
        peerToken: session.peerToken,
        startedAt: DateTime.now(),
      ),
    );
    _sendSignal(session.rpcSessionId, 'invite', callId);
    _armRingTimeout(VoicePhase.outgoing);
  }

  Future<void> accept() async {
    if (_state.phase != VoicePhase.incoming) {
      throw StateError('当前没有待接听的通话');
    }
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      throw StateError('需要麦克风权限才能接听');
    }
    final chatRpc = _state.chatRpcId;
    final callId = _state.callId;
    _setState(_state.copyWith(
      phase: VoicePhase.active,
      startedAt: DateTime.now(),
      clearError: true,
    ));
    _cancelRing();
    _sendSignal(chatRpc, 'accept', callId);
  }

  Future<void> rejectOrCancel() async {
    final op = switch (_state.phase) {
      VoicePhase.incoming => 'reject',
      VoicePhase.outgoing => 'cancel',
      _ => 'hangup',
    };
    await _endLocal(op: op, closeVoiceTransport: true);
  }

  Future<void> hangup() async {
    await _endLocal(op: 'hangup', closeVoiceTransport: true);
  }

  void setMuted(bool muted) {
    if (_state.phase == VoicePhase.idle) return;
    _audio.muted = muted;
    _setState(_state.copyWith(muted: muted));
  }

  void onSignal(int chatRpcId, Map<String, dynamic> data) {
    final op = ('${data['op'] ?? ''}').trim();
    final callId = ('${data['callId'] ?? ''}').trim();
    if (op.startsWith('vcall_')) return;
    switch (op) {
      case 'invite':
        _onInvite(chatRpcId, callId);
        break;
      case 'accept':
        _onAccept(chatRpcId, callId);
        break;
      case 'reject':
      case 'cancel':
      case 'hangup':
      case 'busy':
      case 'timeout':
        _onRemoteEnd(chatRpcId, callId);
        break;
    }
  }

  void onVoiceSessionSignal(int chatRpcId, Map<String, dynamic> data) {
    final op = ('${data['op'] ?? ''}').trim();
    final callId = ('${data['callId'] ?? ''}').trim();
    final voiceSid = (data['sessionId'] as num?)?.toInt() ?? 0;
    if (callId.isEmpty) return;
    if (op == 'start') {
      unawaited(_onVoiceSessionStart(chatRpcId, callId, voiceSid));
    } else if (op == 'stop') {
      if (_state.chatRpcId == chatRpcId &&
          (_state.callId.isEmpty || _state.callId == callId)) {
        unawaited(_clearIdle(closeVoiceTransport: true));
      }
    }
  }

  void onAudioBinary(int sessionId, Uint8List bytes) {
    if (_state.phase != VoicePhase.active) return;
    if (_state.voiceRpcId == 0 || _state.voiceRpcId != sessionId) return;
    final parsed = parseVoiceBinary(bytes);
    if (parsed == null) return;
    if (parsed.callId.isNotEmpty &&
        _state.callId.isNotEmpty &&
        parsed.callId != _state.callId) {
      return;
    }
    _audio.pushRemoteOpus(parsed.opus);
  }

  void onChatSessionDead(int chatRpcId) {
    if (_state.chatRpcId == chatRpcId && isBusy) {
      unawaited(_clearIdle(closeVoiceTransport: true));
    }
  }

  Future<void> shutdown() => _clearIdle(closeVoiceTransport: true);

  void _onInvite(int chatRpcId, String callId) {
    if (callId.isEmpty) return;
    if (isBusy) {
      if (_state.chatRpcId == chatRpcId && _state.callId == callId) return;
      _sendSignal(chatRpcId, 'busy', callId);
      return;
    }
    final session = _chat.sessionByRpc(chatRpcId);
    _isInviter = false;
    _peerPass = session?.peerPass ?? '';
    _setState(
      VoiceUiState(
        phase: VoicePhase.incoming,
        chatSessionLocalId: session?.id ?? '',
        chatRpcId: chatRpcId,
        callId: callId,
        peerToken: session?.peerToken ?? '',
        startedAt: DateTime.now(),
      ),
    );
    _armRingTimeout(VoicePhase.incoming);
  }

  void _onAccept(int chatRpcId, String callId) {
    if (_state.phase != VoicePhase.outgoing ||
        !_isInviter ||
        _state.chatRpcId != chatRpcId) {
      return;
    }
    if (callId.isNotEmpty && _state.callId != callId) return;
    _cancelRing();
    _setState(_state.copyWith(
      phase: VoicePhase.active,
      startedAt: DateTime.now(),
    ));
    unawaited(_inviterBeginVoice());
  }

  Future<void> _inviterBeginVoice() async {
    final chatRpc = _state.chatRpcId;
    final callId = _state.callId;
    final session = _chat.sessionByRpc(chatRpc);
    final pass = _peerPass.isNotEmpty
        ? _peerPass
        : (session?.peerPass.trim() ?? '');
    final peer = session?.peerToken ?? _state.peerToken;
    if (peer.isEmpty || pass.isEmpty) {
      await _failAndHangup(chatRpc, callId, '语音会话创建失败：缺少对端信息');
      return;
    }
    int voiceId = 0;
    try {
      voiceId = _webrpc.openSession(peer, permission: pass);
      if (voiceId == 0) {
        throw StateError('OpenSession=0');
      }
      // Match Desktop: hello on media session after OpenSession.
      final helloOk = _webrpc.sendJson(voiceId, {
        'type': 1,
        'data': {
          'sessionId': voiceId,
          'token': _webrpc.currentToken,
          'permission': _webrpc.currentPermission,
        },
      }, timeoutMs: 10000);
      if (!helloOk) {
        _webrpc.closeSession(voiceId);
        throw StateError('语音握手失败');
      }
      _knownMediaSessions.add(voiceId);
      if (_state.phase != VoicePhase.active ||
          !_isInviter ||
          _state.callId != callId) {
        _webrpc.closeSession(voiceId);
        return;
      }
      _setState(_state.copyWith(voiceRpcId: voiceId));
      _sendVoiceSessionSignal(chatRpc, 'start', callId, voiceId);
      await _startMedia(voiceId, callId);
    } catch (e, st) {
      debugPrint('voice inviter begin failed: $e\n$st');
      if (voiceId != 0) {
        try {
          _webrpc.closeSession(voiceId);
        } catch (_) {}
      }
      await _failAndHangup(chatRpc, callId, '语音会话创建失败');
    }
  }

  Future<void> _onVoiceSessionStart(
    int chatRpcId,
    String callId,
    int voiceSessionId,
  ) async {
    if (voiceSessionId == 0) return;
    if (_isInviter) return;
    if (_state.chatRpcId != chatRpcId || _state.callId != callId) return;
    _knownMediaSessions.add(voiceSessionId);
    _cancelRing();
    _setState(_state.copyWith(
      phase: VoicePhase.active,
      voiceRpcId: voiceSessionId,
      startedAt: DateTime.now(),
    ));
    try {
      await _startMedia(voiceSessionId, callId);
    } catch (e, st) {
      debugPrint('voice callee media failed: $e\n$st');
      _sendVoiceSessionSignal(chatRpcId, 'stop', callId, voiceSessionId);
      _sendSignal(chatRpcId, 'hangup', callId);
      await _clearIdle(closeVoiceTransport: false);
      _setState(_state.copyWith(error: '语音媒体启动失败'));
    }
  }

  Future<void> _startMedia(int voiceSessionId, String callId) async {
    await _audio.start(
      callId: callId,
      onEncode: (packed) {
        if (_state.phase != VoicePhase.active) return;
        if (_state.voiceRpcId != voiceSessionId) return;
        // timeoutMs=0 like Desktop VOICE_SEND_TIMEOUT_MS
        _webrpc.sendRaw(voiceSessionId, packed, timeoutMs: 0);
      },
    );
    _audio.muted = _state.muted;
    notifyListeners();
  }

  void _onRemoteEnd(int chatRpcId, String callId) {
    if (_state.chatRpcId != chatRpcId) return;
    if (callId.isNotEmpty && _state.callId != callId) return;
    unawaited(_clearIdle(closeVoiceTransport: true));
  }

  Future<void> _failAndHangup(int chatRpc, String callId, String err) async {
    _sendSignal(chatRpc, 'hangup', callId);
    await _clearIdle(closeVoiceTransport: true);
    _setState(VoiceUiState(error: err));
  }

  void clearError() {
    if (_state.error.isEmpty) return;
    _setState(_state.copyWith(clearError: true));
  }

  Future<void> _endLocal({
    required String op,
    required bool closeVoiceTransport,
  }) async {
    if (_state.phase == VoicePhase.idle) return;
    final chatRpc = _state.chatRpcId;
    final callId = _state.callId;
    final voiceId = _state.voiceRpcId;
    final wasInviter = _isInviter;
    await _audio.stop();
    _cancelRing();
    if (voiceId > 0 && chatRpc > 0) {
      _sendVoiceSessionSignal(chatRpc, 'stop', callId, voiceId);
    }
    if (chatRpc > 0 && callId.isNotEmpty) {
      _sendSignal(chatRpc, op, callId);
    }
    if (closeVoiceTransport && wasInviter && voiceId > 0) {
      try {
        _webrpc.closeSession(voiceId);
      } catch (_) {}
      _knownMediaSessions.remove(voiceId);
    }
    _isInviter = false;
    _peerPass = '';
    _setState(VoiceUiState.idle);
  }

  Future<void> _clearIdle({required bool closeVoiceTransport}) async {
    final voiceId = _state.voiceRpcId;
    final wasInviter = _isInviter;
    await _audio.stop();
    _cancelRing();
    if (closeVoiceTransport && wasInviter && voiceId > 0) {
      try {
        _webrpc.closeSession(voiceId);
      } catch (_) {}
      _knownMediaSessions.remove(voiceId);
    }
    _isInviter = false;
    _peerPass = '';
    _setState(VoiceUiState.idle);
  }

  void _sendSignal(int sessionId, String op, String callId) {
    if (sessionId == 0) return;
    _webrpc.sendJson(sessionId, voiceSignalJson(op, callId), timeoutMs: 10000);
  }

  void _sendVoiceSessionSignal(
    int chatSessionId,
    String op,
    String callId,
    int voiceSessionId,
  ) {
    if (chatSessionId == 0 || voiceSessionId == 0) return;
    _webrpc.sendJson(
      chatSessionId,
      voiceSessionSignalJson(
        op: op,
        callId: callId,
        sessionId: voiceSessionId,
      ),
      timeoutMs: 10000,
    );
  }

  void _armRingTimeout(VoicePhase waitPhase) {
    _cancelRing();
    final chatRpc = _state.chatRpcId;
    final callId = _state.callId;
    _ringTimer = Timer(const Duration(milliseconds: kVoiceRingTimeoutMs), () {
      if (_state.phase != waitPhase ||
          _state.chatRpcId != chatRpc ||
          _state.callId != callId) {
        return;
      }
      final op = waitPhase == VoicePhase.outgoing ? 'timeout' : 'reject';
      unawaited(_endLocal(op: op, closeVoiceTransport: true));
    });
  }

  void _cancelRing() {
    _ringTimer?.cancel();
    _ringTimer = null;
  }

  void _setState(VoiceUiState next) {
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }
}
