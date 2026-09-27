import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/chat_models.dart';
import 'chat_store.dart';
import 'drive_controller.dart';
import 'voice_controller.dart';
import 'voice_protocol.dart';
import 'webrpc_service.dart';

class _RecvState {
  _RecvState({required this.size});
  int size;
  int bytes = 0;
  DateTime started = DateTime.now();
  String msgId = '';
  bool resetPending = false;
  String path = '';
}

class ChatController extends ChangeNotifier {
  ChatController({
    required this._webrpc,
    ChatStore? store,
  }) : _store = store ?? ChatStore();

  final WebrpcService _webrpc;
  final ChatStore _store;
  final _uuid = const Uuid();
  VoiceController? _voice;
  DriveController? _drive;

  String _ownerToken = '';
  final List<ChatSession> sessions = [];
  String? selectedId;
  bool loading = false;
  String? lastError;

  void attachVoice(VoiceController voice) => _voice = voice;
  void attachDrive(DriveController drive) => _drive = drive;

  ChatSession? sessionByRpc(int rpcId) => _findByRpc(rpcId);
  ChatSession? sessionByPeer(String token) => _findByPeer(token);

  final Map<String, _RecvState> _recv = {};
  StreamSubscription<WebrpcDataEvent>? _dataSub;
  StreamSubscription<WebrpcFileChunkEvent>? _fileSub;
  StreamSubscription<WebrpcLoginState>? _statusSub;
  Timer? _persistDebounce;

  ChatSession? get selected {
    final id = selectedId;
    if (id == null) return null;
    for (final s in sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> bindOwner(String ownerToken) async {
    await unbind();
    _ownerToken = ownerToken.trim();
    loading = true;
    notifyListeners();
    try {
      final list = await _store.loadSessions(_ownerToken);
      sessions
        ..clear()
        ..addAll(list);
      for (final s in sessions) {
        s.messages
          ..clear()
          ..addAll(await _store.loadMessages(_ownerToken, s.peerToken));
      }
      _dataSub = _webrpc.onData.listen(_onData);
      _fileSub = _webrpc.onFileChunk.listen(_onFileChunk);
      _statusSub = _webrpc.onStatus.listen((st) {
        if (st != WebrpcLoginState.online) {
          unawaited(_voice?.shutdown() ?? Future.value());
          for (final s in sessions) {
            if (s.connected || s.connecting) {
              s.connected = false;
              s.connecting = false;
              s.rpcSessionId = 0;
              s.connectError = '已离线，请重新登录后连接';
            }
          }
          notifyListeners();
        }
      });
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> unbind() async {
    await _voice?.shutdown();
    await _dataSub?.cancel();
    await _fileSub?.cancel();
    await _statusSub?.cancel();
    _dataSub = null;
    _fileSub = null;
    _statusSub = null;
    _persistDebounce?.cancel();
    for (final s in sessions) {
      if (s.rpcSessionId != 0) {
        try {
          _webrpc.closeSession(s.rpcSessionId);
        } catch (_) {}
      }
      s.connected = false;
      s.connecting = false;
      s.rpcSessionId = 0;
    }
    sessions.clear();
    selectedId = null;
    _ownerToken = '';
    _recv.clear();
  }

  void selectSession(String id) {
    selectedId = id;
    notifyListeners();
  }

  Future<ChatSession> createSession({
    required String peerToken,
    String peerPass = '',
    String remark = '',
  }) async {
    final peer = peerToken.trim();
    if (peer.isEmpty) throw ArgumentError('请填写对方 Token');
    if (peer == _ownerToken) throw ArgumentError('不能添加自己的 Token');
    for (final s in sessions) {
      if (s.peerToken == peer) {
        throw StateError('该 Token 已在会话列表中');
      }
    }
    final session = ChatSession(
      id: _uuid.v4(),
      peerToken: peer,
      peerPass: peerPass.trim(),
      remark: remark.trim(),
    );
    sessions.insert(0, session);
    selectedId = session.id;
    await _persistSessions();
    notifyListeners();
    return session;
  }

  Future<void> updateSessionMeta(
    ChatSession session, {
    String? remark,
    String? peerPass,
  }) async {
    if (remark != null) session.remark = remark.trim();
    if (peerPass != null) session.peerPass = peerPass.trim();
    await _persistSessions();
    notifyListeners();
  }

  Future<void> connect(ChatSession session) async {
    if (!_webrpc.isOnline) {
      session.connectError = '请先登录 webrpc';
      notifyListeners();
      return;
    }
    if (session.connecting || session.connected) return;
    session.connecting = true;
    session.connectError = '';
    notifyListeners();
    try {
      final rpcId = await Future<int>(() {
        return _webrpc.openSession(
          session.peerToken,
          permission: session.peerPass,
        );
      });
      if (rpcId == 0) {
        throw StateError('连接失败（OpenSession=0），请检查对方 Token、口令与在线状态');
      }
      final ok = _sendHello(rpcId);
      if (!ok) {
        _webrpc.closeSession(rpcId);
        throw StateError('握手失败，请重试');
      }
      session.rpcSessionId = rpcId;
      session.connected = true;
      session.connecting = false;
      await _persistSessions();
      notifyListeners();
    } catch (e) {
      session.connecting = false;
      session.connected = false;
      session.rpcSessionId = 0;
      session.connectError = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> disconnect(ChatSession session) async {
    final rpc = session.rpcSessionId;
    session.connected = false;
    session.connecting = false;
    session.rpcSessionId = 0;
    session.connectError = '';
    for (final m in session.messages) {
      if (m.status == ChatMsgStatus.sending || m.status == ChatMsgStatus.receiving) {
        m.status = ChatMsgStatus.failed;
      }
    }
    if (rpc != 0) {
      _voice?.onChatSessionDead(rpc);
      try {
        _webrpc.closeSession(rpc);
      } catch (_) {}
    }
    await _persistMessages(session);
    notifyListeners();
  }

  Future<void> deleteSession(ChatSession session) async {
    await disconnect(session);
    sessions.removeWhere((s) => s.id == session.id);
    if (selectedId == session.id) {
      selectedId = sessions.isEmpty ? null : sessions.first.id;
    }
    await _store.deleteSessionData(_ownerToken, session.peerToken);
    await _persistSessions();
    notifyListeners();
  }

  Future<void> clearChat(ChatSession session) async {
    session.messages.clear();
    await _store.clearMessages(_ownerToken, session.peerToken);
    notifyListeners();
  }

  Future<void> sendText(ChatSession session, String text) async {
    final body = text.trim();
    if (body.isEmpty) return;
    _ensureConnected(session);
    final msg = ChatMessage(
      id: _uuid.v4(),
      fromMe: true,
      kind: ChatMsgKind.text,
      content: body,
      title: '',
      time: DateTime.now(),
      status: ChatMsgStatus.sending,
    );
    session.messages.add(msg);
    notifyListeners();
    final ok = _webrpc.sendJson(session.rpcSessionId, {
      'type': 2,
      'data': body,
    });
    msg.status = ok ? ChatMsgStatus.sent : ChatMsgStatus.failed;
    await _persistMessages(session);
    notifyListeners();
    if (!ok) throw StateError('发送失败');
  }

  Future<void> sendFilePath(ChatSession session, String filePath) async {
    _ensureConnected(session);
    final file = File(filePath);
    if (!await file.exists()) throw StateError('文件不存在');
    final name = safeFileName(p.basename(filePath));
    final size = await file.length();
    final msg = ChatMessage(
      id: _uuid.v4(),
      fromMe: true,
      kind: classifyFileName(name),
      content: '',
      title: name,
      time: DateTime.now(),
      status: ChatMsgStatus.sending,
      size: size,
      transferred: 0,
      filePath: filePath,
    );
    session.messages.add(msg);
    notifyListeners();

    // Progress probe like Desktop: type3 before/during SendFile.
    void probe() {
      _webrpc.sendJson(session.rpcSessionId, {
        'type': 3,
        'data': {
          'fileName': name,
          'size': size,
          'msgId': msg.id,
        },
      }, timeoutMs: 0);
    }

    probe();
    final started = DateTime.now();
    final probeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (msg.status != ChatMsgStatus.sending) return;
      probe();
    });

    try {
      final ok = await Future<bool>(() => _webrpc.sendFile(session.rpcSessionId, filePath));
      probeTimer.cancel();
      probe();
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      final safeElapsed = elapsed < 1 ? 1 : elapsed;
      msg.elapsedMs = safeElapsed;
      if (ok) {
        msg.transferred = size;
        msg.speedBps = size * 1000 ~/ safeElapsed;
        msg.status = ChatMsgStatus.sent;
      } else {
        msg.status = ChatMsgStatus.failed;
      }
    } catch (e) {
      probeTimer.cancel();
      msg.status = ChatMsgStatus.failed;
      rethrow;
    } finally {
      await _persistMessages(session);
      notifyListeners();
    }
    if (msg.status == ChatMsgStatus.failed) {
      throw StateError('文件发送失败');
    }
  }

  Future<void> retryMessage(ChatSession session, ChatMessage msg) async {
    if (!msg.fromMe || msg.status != ChatMsgStatus.failed) return;
    if (msg.kind == ChatMsgKind.text) {
      session.messages.remove(msg);
      await sendText(session, msg.content);
      return;
    }
    if (msg.filePath.isEmpty) throw StateError('没有可重发的本地文件');
    session.messages.remove(msg);
    await sendFilePath(session, msg.filePath);
  }

  void _ensureConnected(ChatSession session) {
    if (!session.connected || session.rpcSessionId == 0) {
      throw StateError('会话未连接');
    }
    if (!_webrpc.isOnline) {
      throw StateError('webrpc 未登录');
    }
  }

  bool _sendHello(int rpcSessionId) {
    return _webrpc.sendJson(rpcSessionId, {
      'type': 1,
      'data': {
        'sessionId': rpcSessionId,
        'token': _webrpc.currentToken,
        'permission': _webrpc.currentPermission,
      },
    }, timeoutMs: 10000);
  }

  void _onData(WebrpcDataEvent event) {
    final bytes = event.bytes;
    if (bytes.length >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0) {
      if (isVoiceBinary(bytes)) {
        _voice?.onAudioBinary(event.sessionId, bytes);
      }
      return;
    }
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return;
      json = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }
    final type = json['type'];
    if (type is String) {
      // NAS — ignore in chat phase
      return;
    }
    if (type is! num) return;
    final kind = type.toInt();
    final data = json['data'];
    switch (kind) {
      case 1:
        _onHello(event.sessionId, data);
        break;
      case 2:
        if (data is String) _onText(event.sessionId, data);
        break;
      case 3:
        if (data is Map) _onFileQuery(event.sessionId, Map<String, dynamic>.from(data));
        break;
      case 4:
        if (data is Map) _onFileReply(event.sessionId, Map<String, dynamic>.from(data));
        break;
      case 6:
        if (data is Map) {
          _voice?.onSignal(event.sessionId, Map<String, dynamic>.from(data));
        }
        break;
      case 11:
        if (data is Map) {
          _voice?.onVoiceSessionSignal(
            event.sessionId,
            Map<String, dynamic>.from(data),
          );
        }
        break;
      default:
        break;
    }
  }

  void _onHello(int frameSessionId, dynamic data) {
    if (data is! Map) return;
    final token = ('${data['token'] ?? ''}').trim();
    final permission = ('${data['permission'] ?? ''}').trim();
    final helloSid = (data['sessionId'] as num?)?.toInt() ?? 0;
    if (token.isEmpty) return;
    if (token == _ownerToken) return;

    // Prefer frame session id (same as text/file frames); fall back to hello payload.
    final rpcId = frameSessionId != 0 ? frameSessionId : helloSid;
    if (rpcId == 0) return;

    // Drive / voice media sessions must not become chat sessions.
    if (_drive?.ownsRpc(rpcId) == true || _drive?.ownsPeer(token) == true) {
      return;
    }

    // Voice/media OpenSession hello: same peer, different rpc — do not rebind chat.
    final existingPeer = _findByPeer(token);
    if (existingPeer != null &&
        existingPeer.connected &&
        existingPeer.rpcSessionId != 0 &&
        existingPeer.rpcSessionId != rpcId) {
      _voice?.onInboundSecondarySession(rpcId, existingPeer);
      return;
    }
    if (_voice?.shouldSkipChatHello(rpcId, token) == true) {
      if (existingPeer != null) {
        _voice?.onInboundSecondarySession(rpcId, existingPeer);
      }
      return;
    }

    var session = _findByRpc(rpcId);
    session ??= existingPeer;
    final existed = session != null;
    if (session == null) {
      session = ChatSession(
        id: _uuid.v4(),
        peerToken: token,
        peerPass: permission,
      );
      sessions.insert(0, session);
      selectedId ??= session.id;
    }
    session.peerToken = token;
    if (permission.isNotEmpty) session.peerPass = permission;
    session.rpcSessionId = rpcId;
    session.connected = true;
    session.connecting = false;
    session.connectError = '';
    notifyListeners();
    if (!existed) {
      _persistSessions();
      _store.loadMessages(_ownerToken, token).then((msgs) {
        if (session!.messages.isEmpty && msgs.isNotEmpty) {
          session.messages.addAll(msgs);
          notifyListeners();
        }
      });
    } else {
      _persistSessions();
    }
  }

  void _onText(int rpcSessionId, String text) {
    final session = _findByRpc(rpcSessionId);
    if (session == null) return;
    session.messages.add(
      ChatMessage(
        id: _uuid.v4(),
        fromMe: false,
        kind: ChatMsgKind.text,
        content: text,
        title: '',
        time: DateTime.now(),
        status: ChatMsgStatus.received,
      ),
    );
    _schedulePersist(session);
    notifyListeners();
  }

  void _onFileQuery(int rpcSessionId, Map<String, dynamic> data) {
    final session = _findByRpc(rpcSessionId);
    if (session == null) return;
    final name = safeFileName('${data['fileName'] ?? ''}');
    if (name.isEmpty) return;
    final size = (data['size'] as num?)?.toInt() ?? 0;
    final msgId = ('${data['msgId'] ?? ''}').trim();
    final key = '$rpcSessionId::$name';
    final state = _recv.putIfAbsent(key, () => _RecvState(size: size));
    if (size > 0) state.size = size;
    if (msgId.isNotEmpty) {
      if (state.msgId.isNotEmpty && state.msgId != msgId) {
        state.resetPending = true;
      }
      state.msgId = msgId;
    }
    _webrpc.sendJson(rpcSessionId, {
      'type': 4,
      'data': {'bytes': state.bytes, 'fileName': name},
    }, timeoutMs: 0);

    var msg = _findIncomingFileMsg(session, name, msgId);
    if (msg == null) {
      msg = ChatMessage(
        id: msgId.isNotEmpty ? msgId : _uuid.v4(),
        fromMe: false,
        kind: classifyFileName(name),
        content: '',
        title: name,
        time: DateTime.now(),
        status: ChatMsgStatus.receiving,
        size: state.size,
        transferred: state.bytes,
        filePath: state.path,
      );
      session.messages.add(msg);
    } else {
      msg.size = state.size;
      msg.transferred = state.bytes;
      msg.status = state.size > 0 && state.bytes >= state.size
          ? ChatMsgStatus.received
          : ChatMsgStatus.receiving;
    }
    notifyListeners();
  }

  void _onFileReply(int rpcSessionId, Map<String, dynamic> data) {
    final session = _findByRpc(rpcSessionId);
    if (session == null) return;
    final name = safeFileName('${data['fileName'] ?? ''}');
    final bytes = (data['bytes'] as num?)?.toInt() ?? 0;
    if (name.isEmpty) return;
    for (var i = session.messages.length - 1; i >= 0; i--) {
      final m = session.messages[i];
      if (m.fromMe &&
          m.title == name &&
          (m.status == ChatMsgStatus.sending || m.status == ChatMsgStatus.failed)) {
        m.transferred = bytes;
        if (m.size > 0 && bytes >= m.size) {
          m.status = ChatMsgStatus.sent;
        }
        notifyListeners();
        break;
      }
    }
  }

  Future<void> _onFileChunk(WebrpcFileChunkEvent event) async {
    if (_drive?.ownsRpc(event.sessionId) == true) return;
    final session = _findByRpc(event.sessionId);
    if (session == null) return;
    final name = safeFileName(event.fileName);
    if (name.isEmpty) return;
    final key = '${event.sessionId}::$name';
    final state = _recv.putIfAbsent(key, () => _RecvState(size: 0));
    final reset = state.resetPending ||
        state.bytes == 0 ||
        (state.size > 0 && state.bytes >= state.size);
    if (reset) {
      state.bytes = 0;
      state.started = DateTime.now();
      state.resetPending = false;
      if (state.path.isEmpty) {
        state.path = await _store.incomingPath(_ownerToken, session.peerToken, name);
      }
      final f = File(state.path);
      if (await f.exists()) await f.delete();
    }
    if (state.path.isEmpty) {
      state.path = await _store.incomingPath(_ownerToken, session.peerToken, name);
    }
    final out = File(state.path);
    await out.writeAsBytes(event.bytes, mode: FileMode.append, flush: true);
    state.bytes += event.bytes.length;

    var msg = _findIncomingFileMsg(session, name, state.msgId);
    if (msg == null) {
      msg = ChatMessage(
        id: state.msgId.isNotEmpty ? state.msgId : _uuid.v4(),
        fromMe: false,
        kind: classifyFileName(name),
        content: '',
        title: name,
        time: DateTime.now(),
        status: ChatMsgStatus.receiving,
        size: state.size,
        transferred: state.bytes,
        filePath: state.path,
      );
      session.messages.add(msg);
    } else {
      msg.filePath = state.path;
      msg.transferred = state.bytes;
      if (state.size > 0) msg.size = state.size;
    }

    final complete = state.size > 0 && state.bytes >= state.size;
    final elapsedMs = DateTime.now().difference(state.started).inMilliseconds;
    final elapsed = elapsedMs < 1 ? 1 : elapsedMs;
    msg.elapsedMs = elapsed;
    msg.speedBps = state.bytes * 1000 ~/ elapsed;
    if (complete) {
      msg.status = ChatMsgStatus.received;
      msg.size = state.size;
      msg.transferred = state.bytes;
      _schedulePersist(session);
    }
    notifyListeners();
  }

  ChatMessage? _findIncomingFileMsg(ChatSession session, String name, String msgId) {
    for (var i = session.messages.length - 1; i >= 0; i--) {
      final m = session.messages[i];
      if (m.fromMe) continue;
      if (msgId.isNotEmpty && m.id == msgId) return m;
      if (m.title == name &&
          (m.status == ChatMsgStatus.receiving || m.status == ChatMsgStatus.received)) {
        return m;
      }
    }
    return null;
  }

  ChatSession? _findByRpc(int rpcId) {
    if (rpcId == 0) return null;
    for (final s in sessions) {
      if (s.rpcSessionId == rpcId) return s;
    }
    return null;
  }

  ChatSession? _findByPeer(String token) {
    for (final s in sessions) {
      if (s.peerToken == token) return s;
    }
    return null;
  }

  Future<void> _persistSessions() async {
    if (_ownerToken.isEmpty) return;
    await _store.saveSessions(_ownerToken, sessions);
  }

  Future<void> _persistMessages(ChatSession session) async {
    if (_ownerToken.isEmpty) return;
    await _store.saveMessages(_ownerToken, session.peerToken, session.messages);
  }

  void _schedulePersist(ChatSession session) {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 400), () {
      _persistMessages(session);
    });
  }

  @override
  void dispose() {
    unbind();
    super.dispose();
  }
}
