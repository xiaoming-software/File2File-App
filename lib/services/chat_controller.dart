import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file2file/l10n/app_l10n.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/chat_models.dart';
import '../utils/user_facing_error.dart';
import 'chat_protocol.dart';
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
  /// Serialize inbound file chunks — concurrent async writes corrupted recv state.
  Future<void> _fileChunkTail = Future<void>.value();
  final Map<String, Timer> _deliveryTimers = {};
  StreamSubscription<WebrpcDataEvent>? _dataSub;
  StreamSubscription<WebrpcFileChunkEvent>? _fileSub;
  StreamSubscription<WebrpcLoginState>? _statusSub;
  Timer? _persistDebounce;
  Timer? _heartbeatTimer;
  bool _appForeground = true;
  final Map<String, int> _heartbeatMisses = {};
  final Set<String> _flushingOutbox = {};
  /// >0 while system gallery/file picker is open — defer aggressive reconnect.
  int _mediaPickDepth = 0;
  /// rpcSessionId already answered with our hello (avoid reply loops).
  final Set<int> _helloRepliedRpc = {};
  /// sessionId → pending peer msgIds for type-25 flush (~50ms batch).
  final Map<String, Set<String>> _pendingReadIds = {};
  final Map<String, Timer> _pendingReadTimers = {};

  void beginMediaPick() => _mediaPickDepth++;

  void endMediaPick() {
    if (_mediaPickDepth > 0) _mediaPickDepth--;
  }

  bool get isMediaPicking => _mediaPickDepth > 0;

  Future<void> _waitHealDone({int maxMs = 4000}) async {
    final step = 100;
    var waited = 0;
    while (_healingSessionIds.isNotEmpty && waited < maxMs) {
      await Future<void>.delayed(Duration(milliseconds: step));
      waited += step;
    }
  }

  ChatSession? get selected {
    final id = selectedId;
    if (id == null) return null;
    for (final s in sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> bindOwner(String ownerToken) async {
    final next = ownerToken.trim();
    if (next.isNotEmpty && next == _ownerToken && _dataSub != null) {
      return;
    }
    await unbind();
    _ownerToken = next;
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
      _fileSub = _webrpc.onFileChunk.listen(_enqueueFileChunk);
      _statusSub = _webrpc.onStatus.listen((st) {
        if (st == WebrpcLoginState.connecting) return;
        if (st != WebrpcLoginState.online) {
          unawaited(_voice?.shutdown() ?? Future.value());
          for (final s in sessions) {
            if (s.connected || s.connecting) {
              s.connected = false;
              s.connecting = false;
              s.rpcSessionId = 0;
              s.connectError = '连接已断开，请重新连接'.tr;
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
    _stopHeartbeat();
    for (final s in sessions) {
      if (s.rpcSessionId != 0) {
        try {
          _webrpc.closeSession(s.rpcSessionId);
        } catch (_) {}
      }
      s.connected = false;
      s.connecting = false;
      s.rpcSessionId = 0;
      s.peerCapsAck = false;
      s.peerCapsRead = false;
      s.peerChatProto = 0;
    }
    sessions.clear();
    selectedId = null;
    _ownerToken = '';
    _recv.clear();
    _heartbeatMisses.clear();
    _helloRepliedRpc.clear();
    for (final t in _pendingReadTimers.values) {
      t.cancel();
    }
    _pendingReadTimers.clear();
    _pendingReadIds.clear();
    for (final t in _deliveryTimers.values) {
      t.cancel();
    }
    _deliveryTimers.clear();
    _fileChunkTail = Future<void>.value();
  }

  /// Foreground flag for chat heartbeat (paused in background).
  void setAppForeground(bool foreground) {
    _appForeground = foreground;
    if (foreground) {
      _ensureHeartbeat();
      for (final s in sessions) {
        if (s.connected) {
          unawaited(_flushOutbox(s));
          _flushReadReceiptOutbox(s);
        }
      }
    } else {
      _stopHeartbeat();
    }
  }

  /// 退出并删除该 Token 在本机的会话与文件缓存。
  Future<void> wipeLocalData() async {
    final owner = _ownerToken;
    await unbind();
    if (owner.isNotEmpty) {
      await _store.wipeOwner(owner);
    }
    notifyListeners();
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
    if (peer.isEmpty) throw ArgumentError('请填写对方 Token'.tr);
    if (peer == _ownerToken) throw ArgumentError('不能添加自己的 Token'.tr);
    for (final s in sessions) {
      if (s.peerToken == peer) {
        throw StateError('该 Token 已在会话列表中'.tr);
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
      session.connectError = '请先登录 webrpc'.tr;
      notifyListeners();
      throw StateError(session.connectError);
    }
    if (session.connecting || session.connected) return;
    session.connecting = true;
    session.connectError = '';
    notifyListeners();
    try {
      // OpenSession + hello SendData run off the UI isolate (peer offline stalls).
      final rpcId = await _webrpc.openSessionAsync(
        session.peerToken,
        permission: session.peerPass,
      );
      if (rpcId == 0) {
        throw StateError('连接失败（OpenSession=0），请检查对方 Token、口令与在线状态'.tr);
      }
      final ok = await _sendHelloAsync(rpcId);
      if (!ok) {
        _webrpc.closeSession(rpcId);
        throw StateError('握手失败，请重试'.tr);
      }
      session.rpcSessionId = rpcId;
      session.connected = true;
      session.connecting = false;
      // peerCapsAck / peerCapsRead set when peer hello arrives.
      session.peerCapsAck = false;
      session.peerCapsRead = false;
      session.peerChatProto = 0;
      _helloRepliedRpc.add(rpcId);
      await _persistSessions();
      notifyListeners();
      _ensureHeartbeat();
      unawaited(_flushOutbox(session));
      _flushReadReceiptOutbox(session);
    } catch (e) {
      session.connecting = false;
      session.connected = false;
      session.rpcSessionId = 0;
      session.connectError = userFacingError(
        e,
        fallback: '连接失败，请重试'.tr,
      );
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
    session.peerCapsAck = false;
    session.peerCapsRead = false;
    session.peerChatProto = 0;
    _heartbeatMisses.remove(session.id);
    // Keep `sending` in outbox for reconnect flush; only fail in-flight receives.
    for (final m in session.messages) {
      if (m.status == ChatMsgStatus.receiving) {
        m.status = ChatMsgStatus.failed;
      }
    }
    if (rpc != 0) {
      _helloRepliedRpc.remove(rpc);
      _voice?.onChatSessionDead(rpc);
      try {
        _webrpc.closeSession(rpc);
      } catch (_) {}
    }
    _pendingReadTimers.remove(session.id)?.cancel();
    _pendingReadIds.remove(session.id);
    await _persistMessages(session);
    notifyListeners();
  }

  Future<void> forceReconnect(ChatSession session) async {
    await disconnect(session);
    await connect(session);
  }

  final Set<String> _healingSessionIds = {};

  void _softFlushSession(ChatSession session) {
    if (!session.connected || session.rpcSessionId == 0) return;
    unawaited(_flushOutbox(session));
    _flushReadReceiptOutbox(session);
    _flushInboundDeliveryAcks(session);
  }

  /// Auto-heal chat after background / lock (iOS + Android).
  ///
  /// Healthy sessions only soft-flush — never tear down the rpc (Android gallery
  /// resume used to forceReconnect and race sendFile →「会话未连接」).
  /// OpenSession=0 with healthy transport = peer offline — do **not** full Login.
  Future<void> healAfterForeground(
    ChatSession session, {
    required Future<void> Function({bool forceRelogin}) ensureWebrpc,
  }) async {
    if (_healingSessionIds.contains(session.id)) return;
    if (_mediaPickDepth > 0) {
      debugPrint('chat heal: skip while media picker open');
      return;
    }
    _healingSessionIds.add(session.id);
    debugPrint(
      'chat heal start id=${session.id} connected=${session.connected} '
      'rpc=${session.rpcSessionId} nativeLogin=${_webrpc.nativeLoginAlive} '
      'callback=${_webrpc.callbackStatus}',
    );
    try {
      await ensureWebrpc(forceRelogin: false);

      // Soft path: keep the live session; only re-flush outbox / acks.
      if (session.connected &&
          session.rpcSessionId != 0 &&
          _webrpc.nativeLoginAlive &&
          _webrpc.isCallbackConnected) {
        debugPrint('chat heal: soft keep-alive (no reconnect)');
        _softFlushSession(session);
        return;
      }

      if (!session.connected && !session.connecting) {
        session.connecting = true;
        session.connectError = '';
        notifyListeners();
      }
      var openSessionZero = false;
      try {
        await forceReconnect(session);
      } catch (e) {
        openSessionZero = '$e'.contains('OpenSession=0') ||
            '$e'.contains('连接失败');
        debugPrint('chat heal: forceReconnect threw: $e');
      }
      if (session.connected && _webrpc.isCallbackConnected) {
        debugPrint('chat heal: reconnect ok');
        _softFlushSession(session);
        return;
      }
      // Peer offline / bad token — transport still fine; stop without Login.
      final transportSick =
          !_webrpc.nativeLoginAlive || !_webrpc.isCallbackConnected;
      if (!transportSick) {
        debugPrint(
          'chat heal: stop (peer unreachable, transport ok) '
          'openSessionZero=$openSessionZero',
        );
        session.connecting = false;
        if (session.connectError.isEmpty) {
          session.connectError =
              '无法连接对端，请确认对方在线、Token 与口令正确后重试'.tr;
        }
        notifyListeners();
        return;
      }
      debugPrint(
        'chat heal: escalate full Login '
        '(openSessionZero=$openSessionZero connected=${session.connected} '
        'callback=${_webrpc.callbackStatus})',
      );
      await ensureWebrpc(forceRelogin: true);
      await forceReconnect(session);
      if (!session.connected) {
        session.connectError = '连接已断开，请重新连接'.tr;
        notifyListeners();
      } else {
        _softFlushSession(session);
      }
    } catch (e, st) {
      debugPrint('chat heal fail: $e\n$st');
      session.connectError = userFacingError(
        e,
        fallback: '连接失败，请重试'.tr,
      );
      notifyListeners();
      rethrow;
    } finally {
      if (!session.connected) session.connecting = false;
      _healingSessionIds.remove(session.id);
    }
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
    await _persistMessages(session);
    notifyListeners();
    final ok = _transmitText(session, msg);
    if (!ok) {
      msg.status = ChatMsgStatus.failed;
      await _persistMessages(session);
      notifyListeners();
      throw StateError('发送失败'.tr);
    }
    // Strict delivery: stay `sending` until type-20 →「未读」; else timeout →失败.
    _armDeliveryTimeout(session, msg);
  }

  bool _transmitText(ChatSession session, ChatMessage msg) {
    if (session.rpcSessionId == 0) return false;
    return _webrpc.sendJson(session.rpcSessionId, {
      'type': ChatProtocol.text,
      'data': ChatProtocol.textPayload(msgId: msg.id, text: msg.content),
    });
  }

  Future<void> sendFilePath(ChatSession session, String filePath) async {
    await _waitHealDone();
    if (!session.connected || session.rpcSessionId == 0) {
      // Brief reconnect after gallery resume without forcing callers to heal.
      try {
        await connect(session);
      } catch (_) {}
    }
    _ensureConnected(session);
    final file = File(filePath);
    if (!await file.exists()) throw StateError('文件不存在'.tr);
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
    // Match Desktop: poll type=3 on a timer while SendFile runs off the UI
    // isolate, so type=4 progress replies can update the bubble in real time.
    final probeTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (msg.status != ChatMsgStatus.sending) return;
      probe();
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      if (elapsed > 0 && msg.transferred > 0) {
        msg.elapsedMs = elapsed;
        msg.speedBps = msg.transferred * 1000 ~/ elapsed;
        notifyListeners();
      }
    });

    try {
      // Must not block the UI isolate — same reason drive uses sendFileAsync.
      final ok = await _webrpc.sendFileAsync(session.rpcSessionId, filePath);
      probeTimer.cancel();
      probe();
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      final safeElapsed = elapsed < 1 ? 1 : elapsed;
      msg.elapsedMs = safeElapsed;
      if (ok) {
        msg.transferred = size;
        msg.speedBps = size * 1000 ~/ safeElapsed;
        // Never downgrade 已读/未读 if peer already replied during the transfer.
        if (msg.status == ChatMsgStatus.read ||
            msg.status == ChatMsgStatus.sent) {
          _cancelDeliveryTimeout(msg.id);
        } else {
          // Transport done ≠ delivered; wait for type-20 →「未读」.
          msg.status = ChatMsgStatus.sending;
          _armDeliveryTimeout(session, msg);
        }
      } else if (msg.status != ChatMsgStatus.read &&
          msg.status != ChatMsgStatus.sent) {
        msg.status = ChatMsgStatus.failed;
      }
    } catch (e) {
      probeTimer.cancel();
      if (msg.status != ChatMsgStatus.read && msg.status != ChatMsgStatus.sent) {
        msg.status = ChatMsgStatus.failed;
      }
      rethrow;
    } finally {
      await _persistMessages(session);
      notifyListeners();
    }
    if (msg.status == ChatMsgStatus.failed) {
      throw StateError('文件发送失败'.tr);
    }
  }

  Future<void> retryMessage(ChatSession session, ChatMessage msg) async {
    if (!msg.fromMe || msg.status != ChatMsgStatus.failed) return;
    if (msg.kind == ChatMsgKind.text) {
      session.messages.remove(msg);
      await sendText(session, msg.content);
      return;
    }
    if (msg.filePath.isEmpty) throw StateError('没有可重发的本地文件'.tr);
    session.messages.remove(msg);
    await sendFilePath(session, msg.filePath);
  }

  void _ensureConnected(ChatSession session) {
    if (!session.connected || session.rpcSessionId == 0) {
      throw StateError('会话未连接'.tr);
    }
    if (!_webrpc.isOnline) {
      throw StateError('webrpc 未登录'.tr);
    }
  }

  Future<bool> _sendHelloAsync(int rpcSessionId) {
    return _webrpc.sendJsonAsync(rpcSessionId, {
      'type': ChatProtocol.hello,
      'data': {
        'sessionId': rpcSessionId,
        'token': _webrpc.currentToken,
        'permission': _webrpc.currentPermission,
        ...ChatProtocol.helloExtras(),
      },
    }, timeoutMs: 3000);
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
      case ChatProtocol.hello:
        _onHello(event.sessionId, data);
        break;
      case ChatProtocol.text:
        _onText(event.sessionId, data);
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
      case ChatProtocol.deliveryAck:
        if (data is Map) {
          _onDeliveryAck(event.sessionId, Map<String, dynamic>.from(data));
        }
        break;
      case ChatProtocol.readReceipt:
        if (data is Map) {
          _onReadReceipt(event.sessionId, Map<String, dynamic>.from(data));
        }
        break;
      case ChatProtocol.ping:
        if (data is Map) {
          _onPing(event.sessionId, Map<String, dynamic>.from(data));
        }
        break;
      case ChatProtocol.pong:
        if (data is Map) {
          _onPong(event.sessionId, Map<String, dynamic>.from(data));
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

    // Only skip when THIS frame belongs to an active drive rpc.
    // Do not use ownsPeer — chat and drive can share a peer token with different rpcs.
    if (_drive?.ownsRpc(rpcId) == true) {
      return;
    }

    final existingPeer = _findByPeer(token);

    // Voice/media transport hello: keep chat on its existing rpc.
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
    } else if (session.rpcSessionId != 0 &&
        session.rpcSessionId != rpcId &&
        session.connected) {
      // Peer (e.g. Desktop) OpenSession'd to us — rebind chat to the live rpc,
      // matching Desktop applyPeerHello which always updates rpcSessionId.
      final old = session.rpcSessionId;
      debugPrint(
        'chat: rebind peer=$token rpc ${session.rpcSessionId} -> $rpcId',
      );
      try {
        _webrpc.closeSession(old);
      } catch (_) {}
    }
    session.peerToken = token;
    if (permission.isNotEmpty) session.peerPass = permission;
    session.rpcSessionId = rpcId;
    session.connected = true;
    session.connecting = false;
    session.connectError = '';
    final proto = (data['chatProto'] as num?)?.toInt() ?? 0;
    session.peerChatProto = proto;
    session.peerCapsAck = ChatProtocol.capsIncludeAck(data['caps']);
    session.peerCapsRead = ChatProtocol.capsIncludeRead(data['caps']);
    notifyListeners();
    _ensureHeartbeat();
    // Reply hello so the connector also learns our caps (ack/read).
    _replyHelloIfNeeded(rpcId);
    unawaited(_flushOutbox(session));
    _flushReadReceiptOutbox(session);
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

  /// Resolve chat session for an inbound frame; rebind if Desktop uses a new rpc.
  ChatSession? _sessionForIncoming(int rpcSessionId) {
    if (rpcSessionId == 0) return null;
    if (_drive?.ownsRpc(rpcSessionId) == true) return null;
    if (_voice?.isMediaRpc(rpcSessionId) == true) return null;

    final byRpc = _findByRpc(rpcSessionId);
    if (byRpc != null) return byRpc;

    final token = _webrpc.peerTokenOf(rpcSessionId).trim();
    if (token.isNotEmpty && token != _ownerToken) {
      final byPeer = _findByPeer(token);
      if (byPeer != null) {
        if (byPeer.rpcSessionId != rpcSessionId) {
          debugPrint(
            'chat: attach inbound rpc=$rpcSessionId to peer=$token '
            '(was ${byPeer.rpcSessionId})',
          );
          byPeer.rpcSessionId = rpcSessionId;
          byPeer.connected = true;
          byPeer.connecting = false;
          byPeer.connectError = '';
          notifyListeners();
          unawaited(_persistSessions());
        }
        return byPeer;
      }
    }

    // App↔App: peerTokenOf can lag behind the first file frames. If exactly one
    // live chat session exists, bind this rpc to it so chunks are not dropped.
    final live = sessions
        .where((s) => s.connected && s.rpcSessionId != 0)
        .toList();
    if (live.length == 1) {
      final only = live.first;
      debugPrint(
        'chat: fallback attach rpc=$rpcSessionId → sole session ${only.peerToken}',
      );
      only.rpcSessionId = rpcSessionId;
      return only;
    }
    final anyOpen = sessions.where((s) => s.connected || s.rpcSessionId != 0).toList();
    if (anyOpen.length == 1) {
      final only = anyOpen.first;
      only.rpcSessionId = rpcSessionId;
      only.connected = true;
      only.connecting = false;
      return only;
    }
    return null;
  }

  void _onText(int rpcSessionId, dynamic data) {
    final session = _sessionForIncoming(rpcSessionId);
    if (session == null) return;

    String text;
    String msgId;
    if (data is String) {
      // Legacy bare string — display only, no ACK.
      text = data;
      msgId = '';
    } else if (data is Map) {
      final map = Map<String, dynamic>.from(data);
      text = '${map['text'] ?? ''}';
      msgId = ('${map['msgId'] ?? ''}').trim();
    } else {
      return;
    }
    if (text.isEmpty && msgId.isEmpty) return;

    if (msgId.isNotEmpty) {
      final existing = _findMessageById(session, msgId);
      if (existing != null) {
        _sendDeliveryAck(session, msgId);
        return;
      }
    }

    final msg = ChatMessage(
      id: msgId.isNotEmpty ? msgId : _uuid.v4(),
      fromMe: false,
      kind: ChatMsgKind.text,
      content: text,
      title: '',
      time: DateTime.now(),
      status: ChatMsgStatus.received,
      seenByMe: false,
    );
    session.messages.add(msg);
    notifyListeners();
    // Persist first, then delivery_ack — sender「未读」iff we kept the bubble.
    unawaited(_persistAndAckDelivery(session, msgId));
  }

  Future<void> _persistAndAckDelivery(ChatSession session, String msgId) async {
    await _persistMessages(session);
    if (msgId.isNotEmpty) {
      _sendDeliveryAck(session, msgId);
    }
  }

  void _cancelDeliveryTimeout(String msgId) {
    _deliveryTimers.remove(msgId)?.cancel();
  }

  /// Probe peer to re-ACK; if still no type-20, mark failed so UI stays truthful.
  void _armDeliveryTimeout(ChatSession session, ChatMessage msg) {
    _cancelDeliveryTimeout(msg.id);
    const probes = [2, 5, 12, 20];
    const failAfterSec = 35;
    for (final sec in probes) {
      Future<void>.delayed(Duration(seconds: sec), () {
        if (msg.status != ChatMsgStatus.sending) return;
        if (!session.connected || session.rpcSessionId == 0) return;
        if (msg.kind == ChatMsgKind.text) {
          _transmitText(session, msg);
        } else if (msg.size > 0 && msg.transferred >= msg.size) {
          _probeFileDelivery(session, msg);
        }
      });
    }
    _deliveryTimers[msg.id] = Timer(const Duration(seconds: failAfterSec), () {
      _deliveryTimers.remove(msg.id);
      if (msg.status != ChatMsgStatus.sending) return;
      msg.status = ChatMsgStatus.failed;
      _schedulePersist(session);
      notifyListeners();
    });
  }

  void _onDeliveryAck(int rpcSessionId, Map<String, dynamic> data) {
    final session = _sessionForIncoming(rpcSessionId);
    if (session == null) return;
    final msgId = ('${data['msgId'] ?? ''}').trim();
    if (msgId.isEmpty) return;
    final msg = _findMessageById(session, msgId);
    if (msg == null || !msg.fromMe) return;
    if (msg.status == ChatMsgStatus.read || msg.status == ChatMsgStatus.sent) {
      _cancelDeliveryTimeout(msgId);
      return;
    }
    msg.status = ChatMsgStatus.sent;
    _cancelDeliveryTimeout(msgId);
    if (msg.kind != ChatMsgKind.text && msg.size > 0) {
      msg.transferred = msg.size;
    }
    _schedulePersist(session);
    notifyListeners();
  }

  void _onReadReceipt(int rpcSessionId, Map<String, dynamic> data) {
    final session = _sessionForIncoming(rpcSessionId);
    if (session == null) return;
    final raw = data['msgIds'];
    final ids = <String>[];
    if (raw is List) {
      for (final item in raw) {
        final id = '$item'.trim();
        if (id.isNotEmpty) ids.add(id);
      }
    } else {
      final one = ('${data['msgId'] ?? ''}').trim();
      if (one.isNotEmpty) ids.add(one);
    }
    if (ids.isEmpty) return;
    var changed = false;
    for (final id in ids) {
      final msg = _findMessageById(session, id);
      if (msg == null || !msg.fromMe) continue;
      if (msg.status == ChatMsgStatus.failed) continue;
      if (msg.status == ChatMsgStatus.read) continue;
      msg.status = ChatMsgStatus.read;
      _cancelDeliveryTimeout(id);
      changed = true;
    }
    if (!changed) return;
    _schedulePersist(session);
    notifyListeners();
  }

  /// Viewport / tap / re-enter: always (re)send type-25 for these peer bubbles.
  /// Idempotent on the sender — fixes 已读→未读 races on large file transfers.
  void confirmPeerMessagesRead(ChatSession session, Iterable<String> msgIds) {
    final ids = msgIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) return;
    final idSet = ids.toSet();
    var changed = false;
    for (final m in session.messages) {
      if (m.fromMe) continue;
      if (!idSet.contains(m.id)) continue;
      if (!m.seenByMe) {
        m.seenByMe = true;
        changed = true;
      }
      m.readReceiptPending = true;
    }
    if (changed) {
      _schedulePersist(session);
      notifyListeners();
    }
    _queueReadReceipt(session, ids);
  }

  /// Back-compat name used by the chat UI viewport hooks.
  void markPeerMessagesSeen(ChatSession session, Iterable<String> msgIds) {
    confirmPeerMessagesRead(session, msgIds);
  }

  /// Near-bottom / re-open chat: (re)send read for every peer bubble in the thread.
  void markAllUnseenPeerMessages(ChatSession session) {
    final ids =
        session.messages.where((m) => !m.fromMe).map((m) => m.id).toList();
    if (ids.isEmpty) return;
    confirmPeerMessagesRead(session, ids);
  }

  void _queueReadReceipt(ChatSession session, List<String> msgIds) {
    if (msgIds.isEmpty) return;
    final bucket = _pendingReadIds.putIfAbsent(session.id, () => <String>{});
    bucket.addAll(msgIds);
    if (session.rpcSessionId == 0) {
      _schedulePersist(session);
      return;
    }
    _pendingReadTimers[session.id]?.cancel();
    _pendingReadTimers[session.id] = Timer(const Duration(milliseconds: 50), () {
      _pendingReadTimers.remove(session.id);
      final ids = _pendingReadIds.remove(session.id)?.toList() ?? const [];
      if (ids.isEmpty) return;
      _flushReadReceipt(session, ids);
    });
  }

  void _flushReadReceipt(ChatSession session, List<String> msgIds) {
    if (session.rpcSessionId == 0 || msgIds.isEmpty) return;
    final ok = _webrpc.sendJson(session.rpcSessionId, {
      'type': ChatProtocol.readReceipt,
      'data': ChatProtocol.readPayload(msgIds),
    }, timeoutMs: 0);
    if (!ok) return;
    final idSet = msgIds.toSet();
    var changed = false;
    for (final m in session.messages) {
      if (m.fromMe || !idSet.contains(m.id)) continue;
      if (!m.readReceiptPending) continue;
      m.readReceiptPending = false;
      changed = true;
    }
    if (changed) {
      _schedulePersist(session);
      notifyListeners();
    }
  }

  /// Reconnect / soft-heal: resend type-25 for every peer bubble already seen.
  void _flushReadReceiptOutbox(ChatSession session) {
    if (!session.connected || session.rpcSessionId == 0) return;
    final ids = session.messages
        .where((m) => !m.fromMe && m.seenByMe)
        .map((m) => m.id)
        .toList();
    if (ids.isEmpty) return;
    _flushReadReceipt(session, ids);
  }

  void _replyHelloIfNeeded(int rpcSessionId) {
    if (rpcSessionId == 0) return;
    if (_helloRepliedRpc.contains(rpcSessionId)) return;
    _helloRepliedRpc.add(rpcSessionId);
    _webrpc.sendJson(rpcSessionId, {
      'type': ChatProtocol.hello,
      'data': {
        'sessionId': rpcSessionId,
        'token': _webrpc.currentToken,
        'permission': _webrpc.currentPermission,
        ...ChatProtocol.helloExtras(),
      },
    }, timeoutMs: 0);
  }

  void _onPing(int rpcSessionId, Map<String, dynamic> data) {
    final session = _sessionForIncoming(rpcSessionId);
    if (session == null || session.rpcSessionId == 0) return;
    final t = (data['t'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    _webrpc.sendJson(session.rpcSessionId, {
      'type': ChatProtocol.pong,
      'data': ChatProtocol.pongPayload(t),
    }, timeoutMs: 0);
  }

  void _onPong(int rpcSessionId, Map<String, dynamic> data) {
    final session = _sessionForIncoming(rpcSessionId);
    if (session == null) return;
    _heartbeatMisses[session.id] = 0;
  }

  void _sendDeliveryAck(ChatSession session, String msgId) {
    if (session.rpcSessionId == 0 || msgId.isEmpty) return;
    _webrpc.sendJson(session.rpcSessionId, {
      'type': ChatProtocol.deliveryAck,
      'data': ChatProtocol.ackPayload(msgId),
    }, timeoutMs: 0);
  }

  ChatMessage? _findMessageById(ChatSession session, String msgId) {
    for (final m in session.messages) {
      if (m.id == msgId) return m;
    }
    return null;
  }

  void _probeFileDelivery(ChatSession session, ChatMessage msg) {
    if (session.rpcSessionId == 0 || msg.id.isEmpty || msg.title.isEmpty) return;
    _webrpc.sendJson(session.rpcSessionId, {
      'type': 3,
      'data': {
        'fileName': msg.title,
        'size': msg.size,
        'msgId': msg.id,
      },
    }, timeoutMs: 0);
  }

  /// Re-ACK only messages we truly kept (in list + on disk for files).
  void _flushInboundDeliveryAcks(ChatSession session) {
    if (!session.connected || session.rpcSessionId == 0) return;
    for (final m in session.messages) {
      if (m.fromMe) continue;
      if (m.id.isEmpty) continue;
      if (m.status != ChatMsgStatus.received && m.status != ChatMsgStatus.read) {
        continue;
      }
      unawaited(_ackIfTrulyDelivered(session, m, m.id));
    }
  }

  /// Strict delivery: ACK only after bubble is in the open session and (for files)
  /// the bytes exist on disk. This is what makes sender「未读」mean peer can see it.
  Future<void> _ackIfTrulyDelivered(
    ChatSession session,
    ChatMessage msg,
    String msgId,
  ) async {
    if (msgId.isEmpty || session.rpcSessionId == 0) return;
    final stillThere = session.messages.any((m) => identical(m, msg) || m.id == msg.id);
    if (!stillThere) return;
    if (msg.kind != ChatMsgKind.text) {
      if (msg.filePath.isEmpty) return;
      final f = File(msg.filePath);
      if (!await f.exists()) return;
      if (msg.size > 0) {
        final len = await f.length();
        if (len < msg.size) return;
      }
    }
    await _persistMessages(session);
    // Re-check after await — session may have been rebound/cleared.
    if (!session.messages.any((m) => m.id == msg.id)) return;
    if (session.rpcSessionId == 0) return;
    _sendDeliveryAck(session, msgId);
  }

  Future<void> _flushOutbox(ChatSession session) async {
    if (!session.connected || session.rpcSessionId == 0) return;
    if (_flushingOutbox.contains(session.id)) return;
    _flushingOutbox.add(session.id);
    try {
      final pending = session.messages
          .where((m) => m.fromMe && m.status == ChatMsgStatus.sending)
          .toList();
      for (final msg in pending) {
        if (!session.connected || session.rpcSessionId == 0) break;
        if (msg.kind == ChatMsgKind.text) {
          _transmitText(session, msg);
          continue;
        }
        // Files: never re-SendFile. If bytes already done, re-probe type-3 so
        // the peer can re-send delivery_ack with the correct msgId.
        if (msg.size > 0 && msg.transferred >= msg.size) {
          _probeFileDelivery(session, msg);
        }
      }
    } finally {
      _flushingOutbox.remove(session.id);
    }
  }

  void _onFileQuery(int rpcSessionId, Map<String, dynamic> data) {
    final session = _sessionForIncoming(rpcSessionId);
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
        // New transfer id — never inherit prior bytes (false complete → false ACK).
        state.resetPending = true;
        state.bytes = 0;
        state.path = '';
        state.started = DateTime.now();
      }
      state.msgId = msgId;
    }
    _webrpc.sendJson(rpcSessionId, {
      'type': 4,
      'data': {'bytes': state.bytes, 'fileName': name},
    }, timeoutMs: 0);

    final resolvedId = state.msgId.isNotEmpty ? state.msgId : msgId;
    var msg = _findIncomingFileMsg(session, name, resolvedId);
    final complete = state.size > 0 && state.bytes >= state.size;
    if (msg == null) {
      // Always show a bubble once we know the peer msgId (or have bytes).
      if (resolvedId.isEmpty && state.bytes == 0) {
        notifyListeners();
        return;
      }
      msg = ChatMessage(
        id: resolvedId.isNotEmpty ? resolvedId : _uuid.v4(),
        fromMe: false,
        kind: classifyFileName(name),
        content: '',
        title: name,
        time: DateTime.now(),
        status: complete ? ChatMsgStatus.received : ChatMsgStatus.receiving,
        size: state.size,
        transferred: state.bytes,
        filePath: state.path,
        seenByMe: false,
      );
      session.messages.add(msg);
    } else {
      msg.size = state.size;
      msg.transferred = state.bytes;
      if (state.path.isNotEmpty) msg.filePath = state.path;
      if (complete) {
        msg.status = ChatMsgStatus.received;
      } else if (msg.status != ChatMsgStatus.received &&
          msg.status != ChatMsgStatus.read) {
        msg.status = ChatMsgStatus.receiving;
      }
      if (resolvedId.isNotEmpty && msg.id != resolvedId) {
        final oldId = msg.id;
        msg.id = resolvedId;
        final pending = _pendingReadIds[session.id];
        if (pending != null && pending.remove(oldId)) {
          pending.add(resolvedId);
        }
      }
    }
    notifyListeners();
    // Re-ACK only when this bubble is truly kept (disk verified).
    if (complete && resolvedId.isNotEmpty) {
      if (msg.seenByMe) {
        msg.readReceiptPending = true;
        _queueReadReceipt(session, [resolvedId]);
      }
      unawaited(_ackIfTrulyDelivered(session, msg, resolvedId));
    }
  }

  void _onFileReply(int rpcSessionId, Map<String, dynamic> data) {
    final session = _sessionForIncoming(rpcSessionId);
    if (session == null) return;
    final name = safeFileName('${data['fileName'] ?? ''}');
    final bytes = (data['bytes'] as num?)?.toInt() ?? 0;
    if (name.isEmpty) return;
    for (var i = session.messages.length - 1; i >= 0; i--) {
      final m = session.messages[i];
      if (m.fromMe &&
          m.title == name &&
          (m.status == ChatMsgStatus.sending || m.status == ChatMsgStatus.failed)) {
        // Desktop applyFilePayload: only move progress forward.
        if (bytes >= m.transferred) {
          m.transferred = bytes;
        }
        final elapsed = DateTime.now().difference(m.time).inMilliseconds;
        if (elapsed > 0 && m.transferred > 0) {
          m.elapsedMs = elapsed;
          m.speedBps = m.transferred * 1000 ~/ elapsed;
        }
        if (m.size > 0 &&
            m.transferred >= m.size &&
            m.status != ChatMsgStatus.read &&
            m.status != ChatMsgStatus.sent) {
          // Bytes complete; wait for delivery_ack before「未读」.
          m.status = ChatMsgStatus.sending;
        }
        notifyListeners();
        break;
      }
    }
  }

  void _enqueueFileChunk(WebrpcFileChunkEvent event) {
    _fileChunkTail = _fileChunkTail.then((_) async {
      try {
        await _onFileChunk(event);
      } catch (e, st) {
        debugPrint('chat file chunk failed: $e\n$st');
      }
    });
  }

  Future<void> _onFileChunk(WebrpcFileChunkEvent event) async {
    if (_drive?.ownsRpc(event.sessionId) == true) return;
    if (_voice?.isMediaRpc(event.sessionId) == true) return;
    final session = _sessionForIncoming(event.sessionId);
    if (session == null) {
      debugPrint(
        'chat file chunk dropped: no session for rpc=${event.sessionId} '
        'file=${event.fileName}',
      );
      return;
    }
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
      // Unique path per transfer so same-name files don't clobber each other.
      final fileLabel = state.msgId.isNotEmpty ? '${state.msgId}-$name' : name;
      state.path =
          await _store.incomingPath(_ownerToken, session.peerToken, fileLabel);
      final f = File(state.path);
      if (await f.exists()) await f.delete();
    }
    if (state.path.isEmpty) {
      final fileLabel = state.msgId.isNotEmpty ? '${state.msgId}-$name' : name;
      state.path =
          await _store.incomingPath(_ownerToken, session.peerToken, fileLabel);
    }
    final out = File(state.path);
    await out.parent.create(recursive: true);
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
        seenByMe: false,
      );
      session.messages.add(msg);
    } else {
      msg.filePath = state.path;
      msg.transferred = state.bytes;
      if (state.size > 0) msg.size = state.size;
      if (state.msgId.isNotEmpty && msg.id != state.msgId) {
        final oldId = msg.id;
        msg.id = state.msgId;
        final pending = _pendingReadIds[session.id];
        if (pending != null && pending.remove(oldId)) {
          pending.add(state.msgId);
        }
      }
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
      notifyListeners();
      if (state.msgId.isNotEmpty) {
        if (msg.id != state.msgId) msg.id = state.msgId;
        await _ackIfTrulyDelivered(session, msg, state.msgId);
      } else {
        await _persistMessages(session);
      }
      return;
    }
    notifyListeners();
  }

  /// Match by msgId, or only an in-flight receiving bubble — never reuse an
  /// already-received same-name file (that caused false ACKs / missing bubbles).
  ChatMessage? _findIncomingFileMsg(ChatSession session, String name, String msgId) {
    if (msgId.isNotEmpty) {
      for (var i = session.messages.length - 1; i >= 0; i--) {
        final m = session.messages[i];
        if (!m.fromMe && m.id == msgId) return m;
      }
    }
    for (var i = session.messages.length - 1; i >= 0; i--) {
      final m = session.messages[i];
      if (m.fromMe) continue;
      if (m.title == name && m.status == ChatMsgStatus.receiving) return m;
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

  void _ensureHeartbeat() {
    if (!_appForeground) return;
    if (_heartbeatTimer != null) return;
    _heartbeatTimer = Timer.periodic(ChatProtocol.heartbeatInterval, (_) {
      unawaited(_tickHeartbeat());
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> _tickHeartbeat() async {
    if (!_appForeground || !_webrpc.isOnline) return;
    final connected = sessions.where((s) => s.connected && s.rpcSessionId != 0);
    if (connected.isEmpty) {
      _stopHeartbeat();
      return;
    }
    for (final session in connected.toList()) {
      // Keep delivery/read outboxes moving on a live link (files especially).
      unawaited(_flushOutbox(session));
      _flushReadReceiptOutbox(session);
      _flushInboundDeliveryAcks(session);

      final t = DateTime.now().millisecondsSinceEpoch;
      final ok = _webrpc.sendJson(session.rpcSessionId, {
        'type': ChatProtocol.ping,
        'data': ChatProtocol.pingPayload(t),
      }, timeoutMs: 0);
      final misses = (_heartbeatMisses[session.id] ?? 0) + (ok ? 1 : 1);
      // Count each ping as a miss until pong clears; 3 unanswered → rebuild.
      _heartbeatMisses[session.id] = misses;
      if (misses >= ChatProtocol.heartbeatMissLimit) {
        debugPrint(
          'chat heartbeat: ${session.id} missed $misses → reconnect',
        );
        _heartbeatMisses[session.id] = 0;
        try {
          await forceReconnect(session);
          _softFlushSession(session);
        } catch (e) {
          debugPrint('chat heartbeat reconnect failed: $e');
        }
      }
    }
  }

  @override
  void dispose() {
    unbind();
    super.dispose();
  }
}
