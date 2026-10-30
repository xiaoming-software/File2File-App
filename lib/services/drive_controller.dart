import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file2file/l10n/app_l10n.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/drive_models.dart';
import '../utils/user_facing_error.dart';
import 'app_debug_log.dart';
import 'drive_media_proxy.dart';
import 'drive_protocol.dart';
import 'drive_store.dart';
import 'media_save_service.dart';
import 'webrpc_service.dart';

class _PutAck {
  _PutAck({
    required this.written,
    required this.size,
    required this.ok,
    required this.error,
  });
  final int written;
  final int size;
  final bool ok;
  final String error;
}

class _ListWait {
  _ListWait(this.path, this.done);
  final String path;
  final Completer<List<NasEntry>> done;
}

class _RecvFile {
  _RecvFile({
    required this.transferId,
    required this.path,
    required this.size,
  });
  final String transferId;
  final String path;
  int size;
  int bytes = 0;
  /// NAS `backFile` arrived. webrpc is async: chunks may still be in flight.
  bool endSignaled = false;
  /// Bumped to cancel an in-flight settle loop when recv is replaced/cancelled.
  int settleEpoch = 0;
}

class _ThumbJob {
  _ThumbJob({
    required this.sessionId,
    required this.peerToken,
    required this.dir,
    required this.name,
    required this.key,
  });
  final String sessionId;
  final String peerToken;
  final String dir;
  final String name;
  final String key;
}

Uint8List _decodeThumbB64(String dataB64) => base64Decode(dataB64);

/// Personal drive (mywebdisk-server) over webrpc string-typed NAS messages.
class DriveController extends ChangeNotifier {
  DriveController({
    required WebrpcService webrpc,
    DriveStore? store,
  })  : _webrpc = webrpc,
        _store = store ?? DriveStore();

  final WebrpcService _webrpc;
  final DriveStore _store;
  final MediaSaveService _mediaSave = MediaSaveService();
  final _uuid = const Uuid();
  /// session.id → local HTTP media proxy (video/audio Range streaming).
  final Map<String, DriveMediaProxy> _mediaProxies = {};

  String _ownerToken = '';
  final List<DriveSession> sessions = [];
  bool loading = false;

  final Map<int, String> _pendingListPath = {};
  final Map<int, Completer<_PutAck>> _putWait = {};
  final Map<int, _ListWait> _verifyList = {};
  final Map<int, Completer<bool>> _listWait = {};
  final Map<String, _RecvFile> _recv = {};
  final Map<String, Completer<bool>> _opWait = {};
  final Map<String, Future<void>> _chunkWriteChain = {};
  final Set<String> _uploadBusy = {};
  final Set<String> _downloadBusy = {};
  final Set<String> _healingSessionIds = {};
  Timer? _heartbeatTimer;
  bool _appForeground = true;
  final Map<String, int> _heartbeatMisses = {};

  /// sessionId::dir::name -> local jpeg path
  final Map<String, String> _thumbPaths = {};
  final Set<String> _thumbPending = {};
  final Set<String> _thumbFailed = {};
  static const thumbEdge = 192;
  /// Keep webrpc free for list/nav; 8 saturated the session and made UI crawl.
  static const int thumbMaxInFlight = 2;

  /// Thumb UI updates only — does NOT rebuild the whole drive browser.
  /// Listeners should only [setState] when their own path changes.
  final ValueNotifier<int> thumbTick = ValueNotifier<int>(0);
  final List<_ThumbJob> _thumbHigh = [];
  final List<_ThumbJob> _thumbLow = [];
  final Map<String, Completer<void>> _thumbRpcWait = {};
  int _thumbInFlight = 0;
  Timer? _thumbNotifyTimer;
  bool _thumbNotifyDirty = false;
  /// Nested pause for getPath / connect (critical RPC).
  int _thumbNavPause = 0;
  /// True while the user is scrolling the file list.
  bool _thumbScrollPaused = false;
  /// fire-and-forget listPath: release nav-pause when backPath arrives.
  final Map<int, void Function()> _thumbReleaseOnList = {};

  bool get _thumbsBlocked => _thumbNavPause > 0 || _thumbScrollPaused;

  void pauseThumbsForNav() {
    _thumbNavPause++;
  }

  void resumeThumbsForNav() {
    if (_thumbNavPause > 0) _thumbNavPause--;
    if (!_thumbsBlocked) _pumpThumbQueue();
  }

  /// Call from the browser while the list/grid is scrolling.
  void setThumbScrollPaused(bool paused) {
    if (_thumbScrollPaused == paused) return;
    _thumbScrollPaused = paused;
    if (!paused) _pumpThumbQueue();
  }

  void _releaseThumbNavForList(int rpc) {
    final rel = _thumbReleaseOnList.remove(rpc);
    rel?.call();
  }

  StreamSubscription<WebrpcDataEvent>? _dataSub;
  StreamSubscription<WebrpcFileChunkEvent>? _fileSub;
  StreamSubscription<WebrpcLoginState>? _statusSub;

  bool ownsRpc(int rpcId) {
    if (rpcId == 0) return false;
    for (final s in sessions) {
      if (s.rpcSessionId == rpcId) return true;
    }
    return false;
  }

  bool ownsPeer(String peerToken) {
    final t = peerToken.trim();
    if (t.isEmpty) return false;
    for (final s in sessions) {
      if (s.peerToken == t) return true;
    }
    return false;
  }

  DriveSession? sessionById(String id) {
    for (final s in sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  DriveSession? sessionByRpc(int rpcId) {
    for (final s in sessions) {
      if (s.rpcSessionId == rpcId) return s;
    }
    return null;
  }

  int get totalActiveTasks {
    var n = 0;
    for (final s in sessions) {
      n += s.activeTaskCount;
    }
    return n;
  }

  Future<void> bindOwner(String ownerToken) async {
    final next = ownerToken.trim();
    // Recovery Login must not wipe in-memory sessions / break an open browser.
    if (next.isNotEmpty && next == _ownerToken && _dataSub != null) {
      return;
    }
    await unbind();
    _ownerToken = next;
    loading = true;
    notifyListeners();
    try {
      sessions
        ..clear()
        ..addAll(await _store.load(_ownerToken));
      _dataSub = _webrpc.onData.listen(_onData);
      _fileSub = _webrpc.onFileChunk.listen(_onFileChunk);
      _statusSub = _webrpc.onStatus.listen((st) {
        // Ignore connecting — silent webrpc recovery must not spam「请重新登录」.
        if (st == WebrpcLoginState.connecting) return;
        if (st != WebrpcLoginState.online) {
          for (final s in sessions) {
            if (s.connected || s.connecting) {
              s.connected = false;
              s.connecting = false;
              s.rpcSessionId = 0;
              s.connectError = '连接已断开，请重新连接'.tr;
              s.listing = false;
            }
          }
          _pendingListPath.clear();
          _recv.clear();
          _failAllWaiting('已离线'.tr);
          notifyListeners();
        }
      });
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// 退出并删除该 Token 在本机的网盘列表与缓存。
  Future<void> wipeLocalData() async {
    final owner = _ownerToken;
    await unbind();
    if (owner.isNotEmpty) {
      await _store.wipeOwner(owner);
    }
    notifyListeners();
  }

  Future<void> unbind() async {
    await _dataSub?.cancel();
    await _fileSub?.cancel();
    await _statusSub?.cancel();
    _dataSub = null;
    _fileSub = null;
    _statusSub = null;
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
    _ownerToken = '';
    _pendingListPath.clear();
    _recv.clear();
    _uploadBusy.clear();
    _downloadBusy.clear();
    _failAllWaiting('已退出'.tr);
  }

  Future<DriveSession> createSession({
    required String peerToken,
    String peerPass = '',
    String remark = '',
  }) async {
    final peer = peerToken.trim();
    final pass = peerPass.trim();
    final note = remark.trim();
    if (peer.isEmpty) throw StateError('请填写网盘 Token'.tr);
    if (peer == _ownerToken) {
      throw StateError('不能使用当前登录 Token（webrpc 不支持自己连自己）'.tr);
    }
    if (sessions.any((s) => s.peerToken == peer)) {
      throw StateError('该网盘已存在'.tr);
    }
    final session = DriveSession(
      id: _uuid.v4(),
      peerToken: peer,
      peerPass: pass,
      remark: note,
    );
    sessions.insert(0, session);
    await _persist();
    notifyListeners();
    return session;
  }

  Future<void> updateMeta(
    DriveSession session, {
    String? remark,
    String? peerPass,
  }) async {
    if (remark != null) session.remark = remark.trim();
    if (peerPass != null) session.peerPass = peerPass.trim();
    await _persist();
    notifyListeners();
  }

  Future<void> connect(DriveSession session) async {
    if (!_webrpc.isOnline) {
      session.connectError = '请先登录 webrpc'.tr;
      notifyListeners();
      throw StateError(session.connectError);
    }
    if (session.peerToken == _ownerToken) {
      throw StateError('不能使用当前登录 Token（webrpc 不支持自己连自己）'.tr);
    }
    if (session.connecting || session.connected) return;
    session.connecting = true;
    session.connectError = '';
    notifyListeners();
    try {
      final rpcId = await _webrpc.openSessionAsync(
        session.peerToken,
        permission: session.peerPass,
      );
      if (rpcId == 0) {
        throw StateError('连接失败（OpenSession=0），请检查网盘 Token、口令与在线状态'.tr);
      }
      final helloOk = await _webrpc.sendJsonAsync(rpcId, {
        'type': 1,
        'data': {
          'sessionId': rpcId,
          'token': _webrpc.currentToken,
          'permission': _webrpc.currentPermission,
          ...DriveProtocol.helloExtras(),
        },
      }, timeoutMs: 3000);
      if (!helloOk) {
        _webrpc.closeSession(rpcId);
        throw StateError('握手失败，请重试'.tr);
      }
      session.rpcSessionId = rpcId;
      session.connected = true;
      session.connecting = false;
      session.peerCapsResume = false;
      session.peerDriveProto = 0;
      final resumePath =
          session.currentPath.isEmpty ? '/' : session.currentPath;
      if (session.entries.isEmpty) {
        session.currentPath = '/';
      }
      await _persist();
      notifyListeners();
      AppDebugLog.log(
        'drive connect ok peer=${session.peerToken} rpc=$rpcId '
        'callback=${_webrpc.callbackStatus}',
      );
      _ensureHeartbeat();
      // Give the Go Accept goroutine a beat to publish receiveConn, then ask.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      requestNasInfo(session);
      await _waitPeerCaps(session);
      await listPath(session, resumePath == '/' ? '/' : resumePath);
      // If backPath never arrives (callback writer was nil), rebind + retry.
      unawaited(_ensureListed(session, rpcId));
      unawaited(_pumpUploads(session));
      unawaited(_pumpDownloads(session));
    } catch (e) {
      AppDebugLog.log('drive connect fail: $e');
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

  /// Tear down webrpc transport only — keep logical session + transfer queue.
  Future<void> detachTransport(DriveSession session) async {
    final rpc = session.rpcSessionId;
    session.connected = false;
    session.connecting = false;
    session.rpcSessionId = 0;
    session.connectError = '';
    session.listing = false;
    session.searching = false;
    session.peerCapsResume = false;
    _heartbeatMisses.remove(session.id);
    // Re-queue in-flight work for resume after rebind (do not mark failed).
    for (final t in session.transfers) {
      if (t.status == DriveTransferStatus.running) {
        t.status = DriveTransferStatus.queued;
        t.error = '';
        t.startedAt = null;
      }
    }
    _dropThumbJobsForSession(session.id);
    if (rpc != 0) {
      _releaseThumbNavForList(rpc);
      _pendingListPath.remove(rpc);
      final lw = _listWait.remove(rpc);
      if (lw != null && !lw.isCompleted) lw.complete(false);
      final put = _putWait.remove(rpc);
      if (put != null && !put.isCompleted) {
        put.complete(_PutAck(written: 0, size: 0, ok: false, error: 'rebind'));
      }
      _recv.removeWhere((k, _) => k.startsWith('$rpc::'));
      try {
        _webrpc.closeSession(rpc);
      } catch (_) {}
    }
    _uploadBusy.remove(session.id);
    _downloadBusy.remove(session.id);
    notifyListeners();
  }

  Future<void> _ensureMediaProxy(DriveSession session) async {
    if (session.rpcSessionId == 0) return;
    final proxy = _mediaProxies.putIfAbsent(
      session.id,
      () => DriveMediaProxy(_webrpc),
    );
    await proxy.ensureStarted(session.rpcSessionId);
    proxy.bindRpc(session.rpcSessionId);
  }

  Future<void> _stopMediaProxy(DriveSession session) async {
    final proxy = _mediaProxies.remove(session.id);
    await proxy?.stop();
  }

  /// HTTP stream URL for in-app video/audio preview (null if proxy not up).
  String? mediaStreamUrl(
    DriveSession session,
    String remoteDir,
    String fileName,
  ) {
    return _mediaProxies[session.id]?.streamUrl(remoteDir, fileName);
  }

  /// User-initiated disconnect — fail open transfers.
  Future<void> disconnect(DriveSession session) async {
    await _stopMediaProxy(session);
    final rpc = session.rpcSessionId;
    session.connected = false;
    session.connecting = false;
    session.rpcSessionId = 0;
    session.connectError = '';
    session.listing = false;
    session.entries = [];
    session.nasInfo = null;
    session.searching = false;
    session.peerCapsResume = false;
    session.peerDriveProto = 0;
    _heartbeatMisses.remove(session.id);
    for (final t in session.transfers) {
      if (t.status == DriveTransferStatus.running ||
          t.status == DriveTransferStatus.queued) {
        t.status = DriveTransferStatus.failed;
        t.error = '连接已重置，请重试'.tr;
      }
    }
    _dropThumbJobsForSession(session.id);
    if (rpc != 0) {
      _releaseThumbNavForList(rpc);
      _pendingListPath.remove(rpc);
      final lw = _listWait.remove(rpc);
      if (lw != null && !lw.isCompleted) lw.complete(false);
      _recv.removeWhere((k, _) => k.startsWith('$rpc::'));
      try {
        _webrpc.closeSession(rpc);
      } catch (_) {}
    }
    _uploadBusy.remove(session.id);
    _downloadBusy.remove(session.id);
    notifyListeners();
  }

  void setAppForeground(bool foreground) {
    _appForeground = foreground;
    if (foreground) {
      _ensureHeartbeat();
    } else {
      _stopHeartbeat();
    }
  }

  void _dropThumbJobsForSession(String sessionId) {
    bool drop(_ThumbJob j) => j.sessionId == sessionId;
    _thumbHigh.removeWhere((j) {
      if (!drop(j)) return false;
      _thumbPending.remove(j.key);
      return true;
    });
    _thumbLow.removeWhere((j) {
      if (!drop(j)) return false;
      _thumbPending.remove(j.key);
      return true;
    });
    final prefix = '$sessionId::';
    final keys = _thumbRpcWait.keys.where((k) => k.startsWith(prefix)).toList();
    for (final k in keys) {
      final c = _thumbRpcWait.remove(k);
      if (c != null && !c.isCompleted) c.complete();
      _thumbPending.remove(k);
    }
  }

  Future<void> deleteSession(DriveSession session) async {
    await disconnect(session);
    sessions.removeWhere((s) => s.id == session.id);
    await _store.deleteDriveData(_ownerToken, session.peerToken);
    await _persist();
    notifyListeners();
  }

  Future<void> _waitPeerCaps(DriveSession session) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (session.peerDriveProto > 0 || session.peerCapsResume) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  void requestNasInfo(DriveSession session) {
    if (!session.connected || session.rpcSessionId == 0) return;
    _webrpc.sendJson(session.rpcSessionId, {'type': 'getNasInfo'}, timeoutMs: 10000);
  }

  Future<void> listPath(DriveSession session, String path) async {
    await listPathAndWait(
      session,
      path,
      timeout: const Duration(seconds: 15),
      waitForResult: false,
    );
  }

  /// Sends getPath. When [waitForResult] is true, waits for backPath (or timeout).
  Future<bool> listPathAndWait(
    DriveSession session,
    String path, {
    Duration timeout = const Duration(seconds: 8),
    bool waitForResult = true,
  }) async {
    // Yield webrpc to directory navigation — thumbs resume when listing settles.
    pauseThumbsForNav();
    var released = false;
    void release() {
      if (released) return;
      released = true;
      resumeThumbsForNav();
    }

    try {
      _ensureConnected(session);
      final dir = normalizeNasPath(path);
      final rpc = session.rpcSessionId;
      session.listing = true;
      session.listError = '';
      session.listSeq += 1;
      final seq = session.listSeq;
      session.currentPath = dir;
      _pendingListPath[rpc] = dir;
      Completer<bool>? wait;
      if (waitForResult) {
        final prev = _listWait.remove(rpc);
        if (prev != null && !prev.isCompleted) prev.complete(false);
        wait = Completer<bool>();
        _listWait[rpc] = wait;
      }
      notifyListeners();
      AppDebugLog.log(
        'drive listPath rpc=$rpc path=$dir seq=$seq '
        'callback=${_webrpc.callbackStatus}',
      );
      final ok = _webrpc.sendJson(
        rpc,
        {'type': 'getPath', 'data': dir},
        timeoutMs: 15000,
      );
      if (!ok) {
        AppDebugLog.log('drive listPath send failed path=$dir');
        if (session.listSeq == seq) {
          session.listing = false;
          session.listError = '列目录超时，请重试'.tr;
          notifyListeners();
        }
        final c = _listWait.remove(rpc);
        if (c != null && !c.isCompleted) c.complete(false);
        release();
        return false;
      }
      if (wait == null) {
        // Keep pause until backPath (or disconnect) so return/up stays snappy.
        _thumbReleaseOnList[rpc] = release;
        return true;
      }
      try {
        final r = await wait.future.timeout(timeout);
        release();
        return r;
      } on TimeoutException {
        AppDebugLog.log('drive listPath wait timeout path=$dir rpc=$rpc');
        if (session.listSeq == seq) {
          session.listing = false;
          if (session.listError.isEmpty) {
            session.listError = '列目录超时，请重试'.tr;
          }
          notifyListeners();
        }
        final c = _listWait.remove(rpc);
        if (c != null && !c.isCompleted) c.complete(false);
        release();
        return false;
      }
    } catch (e) {
      release();
      rethrow;
    }
  }

  Future<void> refresh(DriveSession session) =>
      listPath(session, session.currentPath);

  /// Always tear down and open a fresh NAS rpc (even if UI says connected).
  Future<void> forceReconnect(
    DriveSession session, {
    String? resumePath,
  }) async {
    final path = normalizeNasPath(
      resumePath ?? (session.currentPath.isEmpty ? '/' : session.currentPath),
    );
    AppDebugLog.log('drive forceReconnect peer=${session.peerToken} path=$path');
    if (path.isNotEmpty) session.currentPath = path;
    await detachTransport(session);
    await connect(session);
    if (session.connected && path != '/') {
      await listPathAndWait(session, path);
    }
  }

  /// Seamless heal after background / lock (iOS + Android).
  ///
  /// Escalates to full webrpc Login when LoginStatus==0, OpenSession==0,
  /// callback refused, or reconnect still cannot list (zombie LoginStatus=1).
  Future<void> healAfterForeground(
    DriveSession session, {
    required Future<void> Function({bool forceRelogin}) ensureWebrpc,
  }) async {
    if (_healingSessionIds.contains(session.id)) return;
    _healingSessionIds.add(session.id);
    final path = session.currentPath.isEmpty ? '/' : session.currentPath;
    AppDebugLog.log(
      'drive heal start id=${session.id} connected=${session.connected} '
      'entries=${session.entries.length} path=$path '
      'nativeLogin=${_webrpc.nativeLoginAlive} '
      'callback=${_webrpc.callbackStatus}',
    );
    try {
      if (!session.connected && !session.connecting) {
        session.connecting = true;
        session.connectError = '';
        notifyListeners();
      }
      // Soft: rebind, or full Login if callback port is dead.
      await ensureWebrpc(forceRelogin: false);

      if (session.connected) {
        // Short soft probe — long waits make the UI feel frozen.
        final ok = await listPathAndWait(
          session,
          path,
          timeout: const Duration(milliseconds: 2500),
        );
        if (ok) {
          AppDebugLog.log('drive heal: soft list ok');
          return;
        }
      }

      AppDebugLog.log('drive heal: forceReconnect');
      var openSessionZero = false;
      try {
        await forceReconnect(session, resumePath: path);
      } catch (e) {
        openSessionZero = '$e'.contains('OpenSession=0') ||
            '$e'.contains('连接失败');
        AppDebugLog.log('drive heal: forceReconnect threw: $e');
      }
      if (!openSessionZero &&
          session.connected &&
          (session.entries.isNotEmpty ||
              await listPathAndWait(
                session,
                path,
                timeout: const Duration(seconds: 3),
              ))) {
        AppDebugLog.log('drive heal: reconnect ok');
        return;
      }

      // Peer offline with healthy transport — do not full Login.
      final transportSick =
          !_webrpc.nativeLoginAlive || !_webrpc.isCallbackConnected;
      if (openSessionZero && !transportSick) {
        AppDebugLog.log('drive heal: stop (peer unreachable, transport ok)');
        session.connecting = false;
        if (session.connectError.isEmpty) {
          session.connectError =
              '无法连接对端，请确认对方在线、Token 与口令正确后重试'.tr;
        }
        notifyListeners();
        return;
      }

      // Zombie webrpc: callback/login sick — full Login then reconnect.
      AppDebugLog.log(
        'drive heal: escalate full Login '
        '(openSessionZero=$openSessionZero connected=${session.connected} '
        'entries=${session.entries.length} callback=${_webrpc.callbackStatus})',
      );
      await ensureWebrpc(forceRelogin: true);
      await forceReconnect(session, resumePath: path);
      AppDebugLog.log(
        'drive heal done connected=${session.connected} '
        'entries=${session.entries.length} callback=${_webrpc.callbackStatus}',
      );
      if (!session.connected) {
        session.connecting = false;
        session.connectError = '连接已断开，请重新连接'.tr;
        notifyListeners();
      }
    } catch (e, st) {
      AppDebugLog.log('drive heal fail: $e\n$st');
      final tip = userFacingError(e, fallback: '连接失败，请重试'.tr);
      session.listError = tip;
      session.connecting = false;
      if (session.connectError.isEmpty) {
        session.connectError = tip;
      }
      notifyListeners();
      rethrow;
    } finally {
      if (!session.connected) session.connecting = false;
      _healingSessionIds.remove(session.id);
    }
  }

  /// Retries listing when the first getPath reply was dropped (callback writer nil).
  Future<void> _ensureListed(DriveSession session, int rpcId) async {
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (session.rpcSessionId != rpcId || !session.connected) return;
      if (session.entries.isNotEmpty) return;
      AppDebugLog.log(
        'drive list retry #${i + 1} rpc=$rpcId '
        'callback=${_webrpc.callbackStatus} listing=${session.listing}',
      );
      await _webrpc.rebindCallback();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final ok = await listPathAndWait(
        session,
        session.currentPath.isEmpty ? '/' : session.currentPath,
        timeout: const Duration(seconds: 5),
      );
      if (ok) return;
    }
  }

  Future<void> goUp(DriveSession session) =>
      listPath(session, parentNasPath(session.currentPath));

  Future<void> createFolder(DriveSession session, String name) async {
    _ensureConnected(session);
    final n = name.trim().replaceAll(RegExp(r'[\\/\x00]'), '');
    if (n.isEmpty || n == '.' || n == '..' || n.startsWith('.')) {
      throw StateError('文件夹名称无效'.tr);
    }
    final dir = session.currentPath;
    final key = 'create:${session.rpcSessionId}:$dir:$n';
    final c = Completer<bool>();
    _opWait[key] = c;
    final ok = _webrpc.sendJson(
      session.rpcSessionId,
      {
        'type': 'createFile',
        'data': {'name': n, 'path': dir},
      },
      timeoutMs: 15000,
    );
    if (!ok) {
      _opWait.remove(key);
      throw StateError('创建文件夹失败'.tr);
    }
    final success = await c.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _opWait.remove(key);
        return false;
      },
    );
    if (!success) throw StateError('创建文件夹失败'.tr);
    await refresh(session);
  }

  Future<void> rename(
    DriveSession session, {
    required String name,
    required String newName,
  }) async {
    _ensureConnected(session);
    final from = name.trim().replaceAll(RegExp(r'[\\/\x00]'), '');
    final to = newName.trim().replaceAll(RegExp(r'[\\/\x00]'), '');
    if (from.isEmpty || to.isEmpty || to.startsWith('.')) {
      throw StateError('名称无效'.tr);
    }
    final dir = session.currentPath;
    final key = 'rename:${session.rpcSessionId}:$dir:$from';
    final c = Completer<bool>();
    _opWait[key] = c;
    final ok = _webrpc.sendJson(
      session.rpcSessionId,
      {
        'type': 'renameFile',
        'fileName': from,
        'filePath': dir,
        'newFileName': to,
      },
      timeoutMs: 15000,
    );
    if (!ok) {
      _opWait.remove(key);
      throw StateError('重命名失败'.tr);
    }
    final success = await c.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _opWait.remove(key);
        return false;
      },
    );
    if (!success) throw StateError('重命名失败'.tr);
    await refresh(session);
  }

  Future<void> deleteNames(DriveSession session, List<String> names) async {
    _ensureConnected(session);
    final cleaned = names
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && !e.startsWith('.'))
        .toList();
    if (cleaned.isEmpty) return;
    final dir = session.currentPath;
    final key = 'delete:${session.rpcSessionId}:$dir';
    final c = Completer<bool>();
    _opWait[key] = c;
    final ok = _webrpc.sendJson(
      session.rpcSessionId,
      {
        'type': 'deleteFile',
        'fileNames': cleaned,
        'filePath': dir,
      },
      timeoutMs: 30000,
    );
    if (!ok) {
      _opWait.remove(key);
      throw StateError('删除失败'.tr);
    }
    final success = await c.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        _opWait.remove(key);
        return false;
      },
    );
    if (!success) throw StateError('删除失败'.tr);
    await refresh(session);
  }

  Future<void> moveNames(
    DriveSession session, {
    required List<String> names,
    required String fromPath,
    required String targetPath,
  }) async {
    _ensureConnected(session);
    final cleaned = names
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && !e.startsWith('.'))
        .toList();
    if (cleaned.isEmpty) return;
    final from = normalizeNasPath(fromPath);
    final to = normalizeNasPath(targetPath);
    if (to == from) throw StateError('目标目录与当前相同'.tr);
    final key = 'move:${session.rpcSessionId}:$from:$to';
    final c = Completer<bool>();
    _opWait[key] = c;
    final ok = _webrpc.sendJson(
      session.rpcSessionId,
      {
        'type': 'moveFiles',
        'fileNames': cleaned,
        'filePath': from,
        'targetPath': to,
      },
      timeoutMs: 30000,
    );
    if (!ok) {
      _opWait.remove(key);
      throw StateError('移动失败'.tr);
    }
    final success = await c.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        _opWait.remove(key);
        return false;
      },
    );
    if (!success) throw StateError('移动失败'.tr);
    await listPath(session, from);
  }

  Future<void> search(DriveSession session, String keyword) async {
    _ensureConnected(session);
    final kw = keyword.trim();
    if (kw.isEmpty) {
      session.searchHits = [];
      session.searchKeyword = '';
      session.searchError = '';
      notifyListeners();
      return;
    }
    session.searching = true;
    session.searchKeyword = kw;
    session.searchError = '';
    session.searchHits = [];
    notifyListeners();
    final ok = _webrpc.sendJson(
      session.rpcSessionId,
      {'type': 'searchFile', 'fileName': kw},
      timeoutMs: 30000,
    );
    if (!ok) {
      session.searching = false;
      session.searchError = '搜索超时'.tr;
      notifyListeners();
    }
  }

  void clearSearch(DriveSession session) {
    session.searching = false;
    session.searchKeyword = '';
    session.searchHits = [];
    session.searchError = '';
    session.searchTruncated = false;
    notifyListeners();
  }

  /// Queue one or many uploads (serial, Desktop-like).
  void enqueueUploads(DriveSession session, List<String> localPaths) {
    _ensureConnected(session);
    for (final path in localPaths) {
      final name = safeFileName(p.basename(path));
      final file = File(path);
      if (!file.existsSync()) continue;
      final size = file.lengthSync();
      session.transfers.insert(
        0,
        DriveTransfer(
          id: _uuid.v4(),
          kind: DriveTransferKind.upload,
          name: name,
          remoteDir: session.currentPath,
          status: DriveTransferStatus.queued,
          size: size,
          localPath: path,
        ),
      );
    }
    notifyListeners();
    unawaited(_pumpUploads(session));
  }

  /// Queue downloads (serial). Reuses existing queued/running/complete tasks.
  void enqueueDownloads(DriveSession session, List<NasEntry> entries) {
    _ensureConnected(session);
    unawaited(() async {
      for (final entry in entries) {
        if (entry.isDir) continue;
        await startDownload(session, entry, remoteDir: session.currentPath);
      }
    }());
  }

  /// Start or reuse a download. Completes immediately with the transfer handle.
  ///
  /// When [forPreview] is true and a **new** task is created, closing the preview
  /// may cancel it via [releasePreviewDownload].
  ///
  /// Editable text always re-fetches from the NAS (no local cache hit) so App /
  /// Desktop edits stay consistent on Android and iOS.
  Future<DriveTransfer> startDownload(
    DriveSession session,
    NasEntry entry, {
    String? remoteDir,
    bool forPreview = false,
  }) async {
    _ensureConnected(session);
    if (entry.isDir) throw StateError('不能下载目录'.tr);
    final dir = normalizeNasPath(remoteDir ?? session.currentPath);
    final name = safeFileName(entry.name);
    final forceTextRefresh = entry.previewKind == DrivePreviewKind.text;
    // Explicit user download of photos/videos → Photos album (not preview cache).
    final saveAlbum = !forPreview &&
        (entry.previewKind == DrivePreviewKind.image ||
            entry.previewKind == DrivePreviewKind.video);

    if (forceTextRefresh) {
      await _invalidateLocalDownload(session, dir, name);
    }

    final existing = session.findDownload(dir, name);
    if (existing != null) {
      if (existing.status == DriveTransferStatus.queued ||
          existing.status == DriveTransferStatus.running) {
        if (entry.size > 0 && existing.size <= 0) existing.size = entry.size;
        // Shared with another opener — do not cancel when one preview closes.
        existing.cancelableByPreview = false;
        if (saveAlbum) existing.saveMediaToAlbum = true;
        return existing;
      }
      if (!forceTextRefresh &&
          existing.status == DriveTransferStatus.done &&
          await _isLocalComplete(existing, entry.size)) {
        if (entry.size > 0) existing.size = entry.size;
        existing.cancelableByPreview = false;
        if (saveAlbum) {
          existing.saveMediaToAlbum = true;
          unawaited(_exportMediaToAlbumIfNeeded(existing));
        }
        return existing;
      }
      // Failed / cancelled / done-but-stale (text) / empty stub: re-queue.
      if (existing.localPath.isNotEmpty) {
        try {
          final f = File(existing.localPath);
          if (await f.exists()) {
            if (forceTextRefresh) {
              await f.delete();
            } else {
              final len = await f.length();
              final ok = entry.size > 0 ? len >= entry.size : len > 0;
              if (!ok) await f.delete();
            }
          }
        } catch (_) {}
      }
      existing.status = DriveTransferStatus.queued;
      existing.size = entry.size;
      existing.transferred = 0;
      existing.localPath = '';
      existing.error = '';
      existing.resultNote = '';
      existing.cancelRequested = false;
      existing.cancelableByPreview = forPreview;
      existing.saveMediaToAlbum = saveAlbum;
      existing.speedBps = 0;
      existing.startedAt = null;
      notifyListeners();
      unawaited(_pumpDownloads(session));
      return existing;
    }

    // Only reuse orphan local files when listing size is known and matches.
    // size==0 in listings is common for txt; never treat empty stubs as complete.
    // Text never reuses orphans — always fetch from server.
    if (!forceTextRefresh && entry.size > 0) {
      final local =
          await _store.downloadPath(_ownerToken, session.peerToken, name);
      final localFile = File(local);
      if (await localFile.exists()) {
        final len = await localFile.length();
        if (len >= entry.size) {
          final done = DriveTransfer(
            id: _uuid.v4(),
            kind: DriveTransferKind.download,
            name: name,
            remoteDir: dir,
            status: DriveTransferStatus.done,
            size: entry.size,
            transferred: len,
            localPath: local,
            saveMediaToAlbum: saveAlbum,
          );
          session.transfers.insert(0, done);
          notifyListeners();
          if (saveAlbum) unawaited(_exportMediaToAlbumIfNeeded(done));
          return done;
        }
      }
    }

    final t = DriveTransfer(
      id: _uuid.v4(),
      kind: DriveTransferKind.download,
      name: name,
      remoteDir: dir,
      status: DriveTransferStatus.queued,
      size: entry.size,
      cancelableByPreview: forPreview,
      saveMediaToAlbum: saveAlbum,
    );
    session.transfers.insert(0, t);
    notifyListeners();
    unawaited(_pumpDownloads(session));
    return t;
  }

  /// Copy finished image/video into the system album (File2File).
  Future<void> _exportMediaToAlbumIfNeeded(DriveTransfer t) async {
    if (!t.saveMediaToAlbum) return;
    if (t.status != DriveTransferStatus.done) return;
    if (t.localPath.isEmpty) return;
    final kind = drivePreviewKind(t.name);
    if (kind != DrivePreviewKind.image && kind != DrivePreviewKind.video) {
      return;
    }
    try {
      await _mediaSave.savePathToAlbum(
        t.localPath,
        video: kind == DrivePreviewKind.video,
      );
      t.resultNote = '已保存到相册'.tr;
      t.error = '';
      notifyListeners();
    } catch (e) {
      AppDebugLog.log('drive album export failed: $e');
      t.error = AppL10n.current.fill(
        r'已下载，但保存相册失败：$e',
        {r'$e': '$e'},
      );
      notifyListeners();
    }
  }

  Future<DriveTransfer> downloadNow(
    DriveSession session,
    NasEntry entry, {
    String? remoteDir,
  }) async {
    final t = await startDownload(session, entry, remoteDir: remoteDir);
    while (t.status == DriveTransferStatus.queued ||
        t.status == DriveTransferStatus.running) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (t.status == DriveTransferStatus.failed ||
        t.status == DriveTransferStatus.cancelled) {
      throw StateError(t.error.isEmpty ? '下载失败'.tr : t.error);
    }
    return t;
  }

  Future<bool> _isLocalComplete(DriveTransfer t, int expectedSize) async {
    if (t.localPath.isEmpty) return false;
    final f = File(t.localPath);
    if (!await f.exists()) return false;
    final len = await f.length();
    if (len <= 0) return false;
    if (expectedSize > 0) return len >= expectedSize;
    if (t.size > 0) return len >= t.size;
    // Unknown size: only trust if we previously received real bytes.
    return t.transferred > 0 && len >= t.transferred;
  }

  /// Cancel a queued/running download (used by preview dispose and task list).
  void cancelTransfer(DriveSession session, DriveTransfer t) {
    if (t.kind != DriveTransferKind.download) return;
    if (t.status == DriveTransferStatus.queued) {
      t.status = DriveTransferStatus.cancelled;
      t.error = '已取消'.tr;
      t.cancelRequested = false;
      notifyListeners();
      return;
    }
    if (t.status != DriveTransferStatus.running) return;
    t.cancelRequested = true;
    t.error = '已取消'.tr;
    String? recvKey;
    _RecvFile? recv;
    _recv.forEach((k, v) {
      if (v.transferId == t.id) {
        recvKey = k;
        recv = v;
      }
    });
    if (recv != null) recv!.settleEpoch++;
    if (recvKey != null) _recv.remove(recvKey);
    final c = _opWait.remove('dl:${t.id}');
    if (c != null && !c.isCompleted) c.complete(false);
    t.status = DriveTransferStatus.cancelled;
    notifyListeners();
  }

  /// Preview closed: cancel only if this download was created for that preview.
  void releasePreviewDownload(DriveSession session, DriveTransfer t) {
    if (!t.cancelableByPreview) return;
    if (t.status == DriveTransferStatus.queued ||
        t.status == DriveTransferStatus.running) {
      cancelTransfer(session, t);
    }
  }

  Future<void> putTextFile(
    DriveSession session, {
    required String name,
    required String remoteDir,
    required String text,
  }) async {
    _ensureConnected(session);
    final safe = safeFileName(name);
    final dir = normalizeNasPath(remoteDir);
    final tmpDir = await _store.downloadDir(_ownerToken, session.peerToken);
    final tmp = File(p.join(tmpDir.path, '.$safe.edit'));
    await tmp.writeAsString(text, flush: true);
    try {
      await _putLocalFile(
        session,
        localPath: tmp.path,
        name: safe,
        remoteDir: dir,
      );
    } finally {
      try {
        await tmp.delete();
      } catch (_) {}
    }
    // Keep the official download cache in sync with what we just uploaded
    // (next open still re-fetches; this avoids a stale hit if reuse ever changes).
    await _writeTextDownloadCache(session, dir, safe, text);
    if (dir == session.currentPath) {
      await refresh(session);
    }
  }

  Future<void> _invalidateLocalDownload(
    DriveSession session,
    String remoteDir,
    String name,
  ) async {
    try {
      final local =
          await _store.downloadPath(_ownerToken, session.peerToken, name);
      final f = File(local);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> _writeTextDownloadCache(
    DriveSession session,
    String remoteDir,
    String name,
    String text,
  ) async {
    final dir = normalizeNasPath(remoteDir);
    final safe = safeFileName(name);
    final path =
        await _store.downloadPath(_ownerToken, session.peerToken, safe);
    final file = File(path);
    await file.writeAsString(text, flush: true);
    final len = await file.length();
    final existing = session.findDownload(dir, safe);
    if (existing != null) {
      existing.status = DriveTransferStatus.done;
      existing.localPath = path;
      existing.size = len;
      existing.transferred = len;
      existing.error = '';
      existing.cancelRequested = false;
      existing.cancelableByPreview = false;
      existing.speedBps = 0;
    } else {
      session.transfers.insert(
        0,
        DriveTransfer(
          id: _uuid.v4(),
          kind: DriveTransferKind.download,
          name: safe,
          remoteDir: dir,
          status: DriveTransferStatus.done,
          size: len,
          transferred: len,
          localPath: path,
        ),
      );
    }
    notifyListeners();
  }

  Future<void> retryTransfer(DriveSession session, DriveTransfer t) async {
    if (t.status != DriveTransferStatus.failed &&
        t.status != DriveTransferStatus.cancelled) {
      return;
    }
    t.status = DriveTransferStatus.queued;
    t.error = '';
    t.transferred = 0;
    t.cancelRequested = false;
    t.cancelableByPreview = false;
    notifyListeners();
    if (t.kind == DriveTransferKind.upload) {
      unawaited(_pumpUploads(session));
    } else {
      unawaited(_pumpDownloads(session));
    }
  }

  void clearFinishedTasks(DriveSession session) {
    session.transfers.removeWhere(
      (t) =>
          t.status == DriveTransferStatus.done ||
          t.status == DriveTransferStatus.failed ||
          t.status == DriveTransferStatus.cancelled,
    );
    notifyListeners();
  }

  void removeTask(DriveSession session, DriveTransfer t) {
    if (t.status == DriveTransferStatus.running) {
      cancelTransfer(session, t);
      return;
    }
    session.transfers.removeWhere((e) => e.id == t.id);
    notifyListeners();
  }

  DriveTransfer? transferById(DriveSession session, String id) {
    for (final t in session.transfers) {
      if (t.id == id) return t;
    }
    return null;
  }

  String thumbCacheKey(DriveSession session, String remoteDir, String name) {
    return '${session.id}::${normalizeNasPath(remoteDir)}::${safeFileName(name)}';
  }

  String? thumbLocalPath(DriveSession session, String remoteDir, String name) {
    return _thumbPaths[thumbCacheKey(session, remoteDir, name)];
  }

  bool thumbFailed(DriveSession session, String remoteDir, String name) {
    return _thumbFailed.contains(thumbCacheKey(session, remoteDir, name));
  }

  void _scheduleThumbTick() {
    _thumbNotifyDirty = true;
    // Slightly longer coalesce — fewer Image rebuild waves while scrolling.
    _thumbNotifyTimer ??= Timer(const Duration(milliseconds: 200), () {
      _thumbNotifyTimer = null;
      if (!_thumbNotifyDirty) return;
      _thumbNotifyDirty = false;
      thumbTick.value++;
    });
  }

  /// Background enqueue for a whole directory (or search hits). Visible cells
  /// call [prioritizeThumb] to jump the queue. Max [thumbMaxInFlight] in flight.
  void ensureThumbs(
    DriveSession session,
    Iterable<NasEntry> entries, {
    String? remoteDir,
  }) {
    if (!session.connected || session.rpcSessionId == 0) return;
    final dir = normalizeNasPath(remoteDir ?? session.currentPath);
    final list = entries is List<NasEntry> ? entries : entries.toList();
    unawaited(_enqueueThumbsChunked(session, dir, list));
  }

  Future<void> _enqueueThumbsChunked(
    DriveSession session,
    String dir,
    List<NasEntry> entries,
  ) async {
    const chunk = 64;
    var added = false;
    for (var i = 0; i < entries.length; i++) {
      if (!session.connected) return;
      final entry = entries[i];
      if (entry.isDir) continue;
      final kind = entry.previewKind;
      if (kind != DrivePreviewKind.image && kind != DrivePreviewKind.video) {
        continue;
      }
      if (_enqueueThumb(session, dir, entry.name, high: false)) {
        added = true;
      }
      if (i > 0 && i % chunk == 0) {
        if (added) {
          _pumpThumbQueue();
          added = false;
        }
        // Yield so scroll/taps stay responsive while enqueueing thousands.
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (added) _pumpThumbQueue();
  }

  /// Visible list/grid cell — bump this file to the front of the thumb queue.
  void prioritizeThumb(
    DriveSession session,
    String remoteDir,
    String name,
  ) {
    if (!session.connected || session.rpcSessionId == 0) return;
    final kind = drivePreviewKind(name);
    if (kind != DrivePreviewKind.image && kind != DrivePreviewKind.video) {
      return;
    }
    final dir = normalizeNasPath(remoteDir);
    final key = thumbCacheKey(session, dir, name);
    if (_thumbPaths.containsKey(key) || _thumbFailed.contains(key)) return;

    // Already waiting in high queue or in flight.
    if (_thumbPending.contains(key)) {
      final lowIdx = _thumbLow.indexWhere((j) => j.key == key);
      if (lowIdx >= 0) {
        final job = _thumbLow.removeAt(lowIdx);
        _thumbHigh.add(job);
        _pumpThumbQueue();
      }
      return;
    }
    if (_enqueueThumb(session, dir, name, high: true)) {
      _pumpThumbQueue();
    }
  }

  bool _enqueueThumb(
    DriveSession session,
    String dir,
    String name, {
    required bool high,
  }) {
    final key = thumbCacheKey(session, dir, name);
    if (_thumbPaths.containsKey(key) ||
        _thumbPending.contains(key) ||
        _thumbFailed.contains(key)) {
      return false;
    }
    _thumbPending.add(key);
    final job = _ThumbJob(
      sessionId: session.id,
      peerToken: session.peerToken,
      dir: dir,
      name: safeFileName(name),
      key: key,
    );
    if (high) {
      _thumbHigh.add(job);
    } else {
      _thumbLow.add(job);
    }
    return true;
  }

  void _pumpThumbQueue() {
    // Do not start new thumb RPCs while navigating or scrolling — frees webrpc
    // for getPath and keeps the UI thread from decoding a flood of JPEGs.
    if (_thumbsBlocked) return;
    while (_thumbInFlight < thumbMaxInFlight) {
      final job = _thumbHigh.isNotEmpty
          ? _thumbHigh.removeAt(0)
          : (_thumbLow.isNotEmpty ? _thumbLow.removeAt(0) : null);
      if (job == null) return;
      _thumbInFlight++;
      unawaited(() async {
        try {
          await _runThumbJob(job);
        } finally {
          _thumbInFlight--;
          _pumpThumbQueue();
        }
      }());
    }
  }

  Future<void> _runThumbJob(_ThumbJob job) async {
    final session = sessionById(job.sessionId);
    if (session == null || !session.connected || session.rpcSessionId == 0) {
      _thumbPending.remove(job.key);
      return;
    }
    try {
      final cached = await _store.thumbPath(
        _ownerToken,
        job.peerToken,
        job.dir,
        job.name,
        edge: thumbEdge,
      );
      final f = File(cached);
      if (await f.exists() && await f.length() > 0) {
        _thumbPaths[job.key] = cached;
        _thumbPending.remove(job.key);
        _scheduleThumbTick();
        return;
      }
    } catch (_) {}

    // If UI asked us to yield the channel, put the job back and exit.
    if (_thumbsBlocked) {
      _thumbHigh.insert(0, job);
      return;
    }

    // Leaving a folder must NOT cancel — keep downloading into cache as long
    // as this drive session is still connected.
    final live = sessionById(job.sessionId);
    if (live == null || !live.connected || live.rpcSessionId == 0) {
      _thumbPending.remove(job.key);
      return;
    }
    final wait = Completer<void>();
    _thumbRpcWait[job.key] = wait;
    final ok = _webrpc.sendJson(
      live.rpcSessionId,
      {
        'type': 'getThumb',
        'fileName': job.name,
        'filePath': job.dir,
        'maxEdge': thumbEdge,
      },
      timeoutMs: 20000,
    );
    if (!ok) {
      _thumbRpcWait.remove(job.key);
      _thumbPending.remove(job.key);
      _thumbFailed.add(job.key);
      _scheduleThumbTick();
      return;
    }
    try {
      await wait.future.timeout(const Duration(seconds: 25));
    } on TimeoutException {
      _thumbRpcWait.remove(job.key);
      _thumbPending.remove(job.key);
      _thumbFailed.add(job.key);
      _scheduleThumbTick();
    }
  }

  void ensureSearchThumbs(DriveSession session, Iterable<NasSearchHit> hits) {
    for (final hit in hits) {
      if (hit.isDir) continue;
      final kind = drivePreviewKind(hit.name);
      if (kind != DrivePreviewKind.image && kind != DrivePreviewKind.video) {
        continue;
      }
      ensureThumbs(
        session,
        [NasEntry(name: hit.name, isDir: false)],
        remoteDir: hit.filePath,
      );
    }
  }

  Future<void> _onBackThumb(DriveSession session, Map<String, dynamic> json) async {
    final name = safeFileName('${json['fileName'] ?? ''}');
    final dir = normalizeNasPath('${json['filePath'] ?? session.currentPath}');
    if (name.isEmpty) return;
    final key = thumbCacheKey(session, dir, name);
    final wait = _thumbRpcWait.remove(key);
    if (wait != null && !wait.isCompleted) wait.complete();
    _thumbPending.remove(key);
    final ok = json['ok'] == true;
    final dataB64 = '${json['data'] ?? ''}';
    if (!ok || dataB64.isEmpty) {
      _thumbFailed.add(key);
      _scheduleThumbTick();
      return;
    }
    try {
      // Off main isolate — large dirs flood base64 payloads otherwise.
      final bytes = await compute(_decodeThumbB64, dataB64);
      if (bytes.isEmpty) {
        _thumbFailed.add(key);
        _scheduleThumbTick();
        return;
      }
      final path = await _store.thumbPath(
        _ownerToken,
        session.peerToken,
        dir,
        name,
        edge: thumbEdge,
      );
      await File(path).writeAsBytes(bytes, flush: false);
      _thumbPaths[key] = path;
      _thumbFailed.remove(key);
      _scheduleThumbTick();
    } catch (_) {
      _thumbFailed.add(key);
      _scheduleThumbTick();
    }
  }

  Future<void> _pumpUploads(DriveSession session) async {
    if (_uploadBusy.contains(session.id)) return;
    _uploadBusy.add(session.id);
    try {
      while (session.connected) {
        DriveTransfer? next;
        for (final t in session.transfers.reversed) {
          if (t.kind == DriveTransferKind.upload &&
              t.status == DriveTransferStatus.queued) {
            next = t;
            break;
          }
        }
        if (next == null) break;
        await _runUpload(session, next);
      }
    } finally {
      _uploadBusy.remove(session.id);
    }
  }

  Future<void> _pumpDownloads(DriveSession session) async {
    if (_downloadBusy.contains(session.id)) return;
    _downloadBusy.add(session.id);
    try {
      while (session.connected) {
        DriveTransfer? next;
        for (final t in session.transfers.reversed) {
          if (t.kind == DriveTransferKind.download &&
              t.status == DriveTransferStatus.queued) {
            next = t;
            break;
          }
        }
        if (next == null) break;
        await _runDownload(session, next);
      }
    } finally {
      _downloadBusy.remove(session.id);
    }
  }

  Future<void> _runUpload(DriveSession session, DriveTransfer t) async {
    t.status = DriveTransferStatus.running;
    t.startedAt = DateTime.now();
    t.error = '';
    notifyListeners();
    try {
      _ensureConnected(session);
      final path = t.localPath;
      if (path.isEmpty || !await File(path).exists()) {
        throw StateError('本地文件不存在'.tr);
      }
      await _putLocalFile(
        session,
        localPath: path,
        name: t.name,
        remoteDir: t.remoteDir,
        task: t,
      );
      t.transferred = t.size;
      t.status = DriveTransferStatus.done;
      final elapsed =
          DateTime.now().difference(t.startedAt ?? DateTime.now()).inMilliseconds.clamp(1, 1 << 30);
      t.speedBps = t.size * 1000 ~/ elapsed;
      notifyListeners();
      if (t.remoteDir == session.currentPath) {
        await refresh(session);
      }
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('连接已重建') || msg.contains('rebind')) {
        t.status = DriveTransferStatus.queued;
        t.error = '';
      } else {
        t.status = DriveTransferStatus.failed;
        t.error = msg;
      }
      notifyListeners();
    }
  }

  Future<void> _runDownload(DriveSession session, DriveTransfer t) async {
    if (t.cancelRequested || t.status == DriveTransferStatus.cancelled) {
      t.status = DriveTransferStatus.cancelled;
      t.error = t.error.isEmpty ? '已取消'.tr : t.error;
      notifyListeners();
      return;
    }
    t.status = DriveTransferStatus.running;
    t.startedAt = DateTime.now();
    t.error = '';
    t.cancelRequested = false;
    notifyListeners();
    try {
      _ensureConnected(session);
      final local = await _store.downloadPath(
        _ownerToken,
        session.peerToken,
        t.name,
      );
      t.localPath = local;
      final f = File(local);
      var offset = 0;
      if (await f.exists()) {
        final len = await f.length();
        // Only skip network when listing size is known and local file matches.
        if (t.size > 0 && len >= t.size) {
          t.transferred = len;
          t.status = DriveTransferStatus.done;
          notifyListeners();
          return;
        }
        if (session.peerCapsResume && len > 0 && (t.size <= 0 || len < t.size)) {
          offset = len;
          t.transferred = len;
        } else {
          await f.delete();
          offset = 0;
        }
      }
      // IMPORTANT: size==0 often means "unknown" (common for txt), NOT empty.
      // Always request getFile; completion comes from chunks / backFile.
      if (t.cancelRequested) {
        t.status = DriveTransferStatus.cancelled;
        t.error = '已取消'.tr;
        notifyListeners();
        return;
      }
      final key = '${session.rpcSessionId}::${t.name}';
      final done = Completer<bool>();
      final recv = _RecvFile(transferId: t.id, path: local, size: t.size)
        ..bytes = offset;
      _recv[key] = recv;
      _opWait['dl:${t.id}'] = done;
      final req = <String, dynamic>{
        'type': 'getFile',
        'fileName': t.name,
        'filePath': t.remoteDir,
      };
      if (offset > 0) req['offset'] = offset;
      final ok = _webrpc.sendJson(
        session.rpcSessionId,
        req,
        timeoutMs: 15000,
      );
      if (!ok) {
        _recv.remove(key);
        _opWait.remove('dl:${t.id}');
        throw StateError('请求下载失败'.tr);
      }
      final waitSeconds = t.size > 0
          ? (t.size / 1024).clamp(60, 3600).toInt()
          : 600;
      final success = await done.future.timeout(
        Duration(seconds: waitSeconds),
        onTimeout: () {
          _recv.remove(key);
          _opWait.remove('dl:${t.id}');
          return t.status == DriveTransferStatus.done;
        },
      );
      if (t.cancelRequested || t.status == DriveTransferStatus.cancelled) {
        t.status = DriveTransferStatus.cancelled;
        t.error = '已取消'.tr;
        notifyListeners();
        return;
      }
      if (!success && t.status != DriveTransferStatus.done) {
        final detail = t.error.trim();
        throw StateError(detail.isEmpty ? '下载超时或失败'.tr : detail);
      }
      if (t.status == DriveTransferStatus.running) {
        t.status = DriveTransferStatus.done;
      }
      notifyListeners();
    } catch (e) {
      if (t.cancelRequested || t.status == DriveTransferStatus.cancelled) {
        t.status = DriveTransferStatus.cancelled;
        t.error = '已取消'.tr;
      } else if (!session.connected || session.rpcSessionId == 0) {
        t.status = DriveTransferStatus.queued;
        t.error = '';
      } else {
        t.status = DriveTransferStatus.failed;
        t.error = e.toString();
      }
      notifyListeners();
    }
  }

  void _ensureConnected(DriveSession session) {
    if (!session.connected || session.rpcSessionId == 0) {
      throw StateError('网盘未连接'.tr);
    }
    if (!_webrpc.isOnline) {
      throw StateError('webrpc 未登录'.tr);
    }
  }

  void _onData(WebrpcDataEvent event) {
    if (!ownsRpc(event.sessionId)) {
      AppDebugLog.log(
        'drive drop rpc=${event.sessionId} not owned '
        'have=${sessions.map((s) => s.rpcSessionId).toList()}',
      );
      return;
    }
    final bytes = event.bytes;
    if (bytes.length >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0) {
      return;
    }
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return;
      json = Map<String, dynamic>.from(decoded);
    } catch (e) {
      AppDebugLog.log('drive json fail rpc=${event.sessionId}: $e');
      return;
    }
    final type = json['type'];
    final session = sessionByRpc(event.sessionId);
    if (session == null) return;
    // Desktop on_upload_ack: numeric type=4 carries mid-upload byte progress.
    if (type == 4) {
      final data = json['data'];
      if (data is Map) {
        _onUploadProgressAck(session, Map<String, dynamic>.from(data));
      }
      return;
    }
    if (type == DriveProtocol.ping) {
      final data = json['data'];
      final t = data is Map
          ? ((data['t'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch)
          : DateTime.now().millisecondsSinceEpoch;
      _webrpc.sendJson(session.rpcSessionId, {
        'type': DriveProtocol.pong,
        'data': DriveProtocol.pongPayload(t),
      }, timeoutMs: 0);
      return;
    }
    if (type == DriveProtocol.pong) {
      _heartbeatMisses[session.id] = 0;
      return;
    }
    if (type is! String) {
      return;
    }
    switch (type) {
      case 'backNasInfo':
        final data = json['data'];
        if (data is Map) {
          session.nasInfo = NasInfo.fromJson(Map<String, dynamic>.from(data));
        }
        session.peerDriveProto = (json['driveProto'] as num?)?.toInt() ?? 0;
        session.peerCapsResume = DriveProtocol.capsIncludeResume(json['caps']);
        notifyListeners();
        break;
      case 'backPath':
        AppDebugLog.log(
          'drive backPath rpc=${event.sessionId} '
          'keys=${json.keys.join(",")}',
        );
        _onBackPath(session, json);
        break;
      case 'backPut':
        _onBackPut(session, json);
        break;
      case 'backThumb':
        unawaited(_onBackThumb(session, json));
        break;
      case 'backFile':
        // Must await pending chunk writes; otherwise small files finish as 0 bytes.
        unawaited(_onBackFile(session, json));
        break;
      case 'backStat':
        _mediaProxies[session.id]?.onBackStat(json);
        break;
      case 'backRange':
        _mediaProxies[session.id]?.onBackRange(json);
        break;
      case 'backCreateFile':
        _completeOp(
          'create:${session.rpcSessionId}:${normalizeNasPath('${json['path'] ?? '/'}')}:${json['name'] ?? ''}',
          json['ok'] == true,
        );
        break;
      case 'backRenameFile':
        _completeOp(
          'rename:${session.rpcSessionId}:${normalizeNasPath('${json['path'] ?? '/'}')}:${json['fileName'] ?? ''}',
          json['ok'] == true,
        );
        break;
      case 'backDeleteFile':
        _completeOp(
          'delete:${session.rpcSessionId}:${normalizeNasPath('${json['path'] ?? '/'}')}',
          json['ok'] == true || _resultsAllOk(json),
        );
        break;
      case 'backMoveFile':
      case 'backMoveFiles':
        final from = normalizeNasPath('${json['path'] ?? '/'}');
        final to = normalizeNasPath('${json['targetPath'] ?? '/'}');
        _completeOp(
          'move:${session.rpcSessionId}:$from:$to',
          json['ok'] == true || _resultsAllOk(json),
        );
        break;
      case 'backSearchFile':
        _onBackSearch(session, json);
        break;
      default:
        break;
    }
  }

  bool _resultsAllOk(Map<String, dynamic> json) {
    final results = json['results'];
    if (results is! List || results.isEmpty) return false;
    for (final item in results) {
      if (item is! Map || item['ok'] != true) return false;
    }
    return true;
  }

  void _completeOp(String key, bool ok) {
    final c = _opWait.remove(key);
    if (c != null && !c.isCompleted) c.complete(ok);
  }

  void _failAllWaiting(String reason) {
    for (final c in _opWait.values) {
      if (!c.isCompleted) c.complete(false);
    }
    _opWait.clear();
  }

  void _onUploadProgressAck(DriveSession session, Map<String, dynamic> data) {
    final name = safeFileName('${data['fileName'] ?? ''}');
    final bytes = _jsonInt(data['bytes']);
    if (bytes <= 0) return;
    for (final t in session.transfers) {
      if (t.kind != DriveTransferKind.upload ||
          t.status != DriveTransferStatus.running) {
        continue;
      }
      if (name.isNotEmpty && t.name != name) continue;
      if (bytes >= t.transferred) t.transferred = bytes;
      final started = t.startedAt;
      if (started != null && t.transferred > 0) {
        final ms =
            DateTime.now().difference(started).inMilliseconds.clamp(1, 1 << 30);
        t.speedBps = t.transferred * 1000 ~/ ms;
      }
      notifyListeners();
      break;
    }
  }

  void _onBackPut(DriveSession session, Map<String, dynamic> json) {
    final written = _jsonInt(json['written']);
    final size = _jsonInt(json['size']);
    final done = json['done'] == true;
    final ok = json['ok'] == true;
    final error = '${json['error'] ?? ''}';
    for (final t in session.transfers) {
      if (t.kind != DriveTransferKind.upload ||
          t.status != DriveTransferStatus.running) {
        continue;
      }
      if (size > 0) t.size = size;
      if (written >= t.transferred) t.transferred = written;
      final started = t.startedAt;
      if (started != null && t.transferred > 0) {
        final ms = DateTime.now().difference(started).inMilliseconds.clamp(1, 1 << 30);
        t.speedBps = t.transferred * 1000 ~/ ms;
      }
      break;
    }
    if (done) {
      final c = _putWait.remove(session.rpcSessionId);
      if (c != null && !c.isCompleted) {
        c.complete(
          _PutAck(written: written, size: size, ok: ok, error: error),
        );
      }
    }
    notifyListeners();
  }

  void _onBackPath(DriveSession session, Map<String, dynamic> json) {
    final reported = '${json['path'] ?? ''}';
    final queued = _pendingListPath[session.rpcSessionId];
    final path = reported.trim().isEmpty
        ? (queued ?? session.currentPath)
        : normalizeNasPath(reported);
    final data = json['data'];
    final listed = <NasEntry>[];
    if (data is Map) {
      data.forEach((key, value) {
        final name = '$key';
        if (name.isEmpty) return;
        if (value is Map) {
          listed.add(
            NasEntry.fromPathItem(name, Map<String, dynamic>.from(value)),
          );
        }
      });
    }
    listed.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    final entries = listed.where((e) => !e.name.startsWith('.')).toList();
    final verify = _verifyList[session.rpcSessionId];
    if (verify != null && verify.path == path) {
      _verifyList.remove(session.rpcSessionId);
      if (!verify.done.isCompleted) verify.done.complete(listed);
    }
    final queuedPath = queued == null ? null : normalizeNasPath(queued);
    final matchesQueued =
        queuedPath != null && (reported.trim().isEmpty || path == queuedPath);
    if (matchesQueued) _pendingListPath.remove(session.rpcSessionId);
    final forUi = matchesQueued || (queuedPath == null && path == session.currentPath);
    if (!forUi) return;
    session.currentPath = path;
    session.entries = entries;
    session.listing = false;
    session.listError = '';
    final lw = _listWait.remove(session.rpcSessionId);
    if (lw != null && !lw.isCompleted) lw.complete(true);
    _releaseThumbNavForList(session.rpcSessionId);
    // First successful listing → start (or keep) local HTTP media proxy.
    unawaited(_ensureMediaProxy(session));
    notifyListeners();
    // Prefetch after first frame so the list stays interactive.
    final snap = List<NasEntry>.from(entries);
    unawaited(Future<void>.delayed(Duration.zero, () {
      if (session.connected) ensureThumbs(session, snap);
    }));
  }

  Future<void> _putLocalFile(
    DriveSession session, {
    required String localPath,
    required String name,
    required String remoteDir,
    DriveTransfer? task,
  }) async {
    final size = await File(localPath).length();
    final dir = normalizeNasPath(remoteDir);
    final rpc = session.rpcSessionId;
    var offset = 0;
    if (task != null) {
      task.size = size;
      if (session.peerCapsResume &&
          task.transferred > 0 &&
          task.transferred < size) {
        offset = task.transferred;
      } else {
        task.transferred = 0;
        offset = 0;
      }
      notifyListeners();
    }
    final ackWait = Completer<_PutAck>();
    _putWait[rpc] = ackWait;
    final putBody = <String, dynamic>{
      'type': 'putFile',
      'fileName': name,
      'filePath': dir,
      'size': size,
    };
    if (offset > 0) putBody['offset'] = offset;
    final announced = _webrpc.sendJson(rpc, putBody, timeoutMs: 15000);
    if (!announced) {
      _putWait.remove(rpc);
      throw StateError('上传宣告失败'.tr);
    }
    Timer? tick;
    if (task != null) {
      tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
        final started = task.startedAt;
        if (started != null && task.transferred > 0) {
          final ms = DateTime.now().difference(started).inMilliseconds.clamp(1, 1 << 30);
          task.speedBps = task.transferred * 1000 ~/ ms;
        }
        notifyListeners();
      });
    }
    String? slicePath;
    try {
      if (size > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        var sendPath = localPath;
        if (offset > 0) {
          slicePath = await _sliceFileFromOffset(localPath, offset);
          sendPath = slicePath;
        }
        // pthread SendFile — UI isolate stays free for backPut progress ticks.
        await _webrpc.sendFileAsync(rpc, sendPath);
      }
    } finally {
      tick?.cancel();
      if (slicePath != null) {
        try {
          await File(slicePath).delete();
        } catch (_) {}
      }
    }
    // Match Desktop confirm_put: scale wait with file size (cap 10 min).
    final waitSecs = (60 + size ~/ (2 * 1024 * 1024)).clamp(60, 600);
    final ack = ackWait.isCompleted
        ? await ackWait.future
        : await ackWait.future.timeout(
            Duration(seconds: waitSecs),
            onTimeout: () {
              _putWait.remove(rpc);
              return _PutAck(
                written: task?.transferred ?? 0,
                size: size,
                ok: false,
                error: '上传未确认完成'.tr,
              );
            },
          );
    if (ack.error == 'rebind') {
      if (task != null && ack.written > 0) task.transferred = ack.written;
      throw StateError('连接已重建，将自动续传'.tr);
    }
    if (!ack.ok || ack.written != size) {
      if (!(session.peerCapsResume && ack.written > 0 && ack.written < size)) {
        await _deleteRemoteQuiet(session, dir, name);
      } else if (task != null) {
        task.transferred = ack.written;
      }
      final why = ack.error.isEmpty ? '字节数不一致'.tr : ack.error;
      throw StateError(AppL10n.current.fill(r'上传校验失败: $why', {r'$why': why}));
    }
    Object? listErr;
    for (var i = 0; i < 4; i++) {
      if (i > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      try {
        final listed = await _listedSize(session, dir, name);
        if (listed == size) {
          if (task != null) task.transferred = size;
          return;
        }
        listErr = StateError(AppL10n.current.fill(r'目录大小 $listed 与本地 $size 不一致', {r'$listed': '$listed', r'$size': '$size'}));
      } catch (e) {
        listErr = e;
      }
    }
    final msg = '$listErr';
    // Match both the Chinese source and the English translation.
    final timedOut =
        msg.contains('超时') || msg.toLowerCase().contains('timed out');
    if (!timedOut) {
      await _deleteRemoteQuiet(session, dir, name);
    }
    throw StateError(AppL10n.current.fill(r'目录核对失败: $msg', {r'$msg': msg}));
  }

  Future<int> _listedSize(DriveSession session, String dir, String name) async {
    final rpc = session.rpcSessionId;
    final wait = Completer<List<NasEntry>>();
    _verifyList[rpc] = _ListWait(dir, wait);
    final ok = _webrpc.sendJson(
      rpc,
      {'type': 'getPath', 'data': dir},
      timeoutMs: 15000,
    );
    if (!ok) {
      _verifyList.remove(rpc);
      throw StateError('目录核对超时'.tr);
    }
    final entries = await wait.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _verifyList.remove(rpc);
        throw StateError('目录核对超时'.tr);
      },
    );
    for (final entry in entries) {
      if (!entry.isDir && entry.name == name) return entry.size;
    }
    throw StateError('目录中没有该文件'.tr);
  }

  Future<void> _deleteRemoteQuiet(DriveSession session, String dir, String name) async {
    final key = 'delete:${session.rpcSessionId}:$dir';
    final c = Completer<bool>();
    _opWait[key] = c;
    final ok = _webrpc.sendJson(
      session.rpcSessionId,
      {
        'type': 'deleteFile',
        'fileNames': [name],
        'filePath': dir,
      },
      timeoutMs: 15000,
    );
    if (!ok) {
      _opWait.remove(key);
      return;
    }
    try {
      await c.future.timeout(const Duration(seconds: 20), onTimeout: () => false);
    } catch (_) {}
  }

  int _jsonInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? 0;
    return 0;
  }

  Future<void> _drainChunkWrites(String key) async {
    // Chunk handler is async and scheduled via broadcast listen; backFile can
    // arrive while writes are still queued. Drain until the chain is idle.
    for (var i = 0; i < 100; i++) {
      final pending = _chunkWriteChain[key];
      if (pending == null) break;
      try {
        await pending;
      } catch (_) {}
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<int> _recvLocalBytes(_RecvFile recv) async {
    var bytes = recv.bytes;
    try {
      final f = File(recv.path);
      if (await f.exists()) {
        final len = await f.length();
        if (len > bytes) bytes = len;
      }
    } catch (_) {}
    return bytes;
  }

  int _recvSettleSeconds(_RecvFile recv) {
    // Mirror Desktop wait_for_nas_cache (90s+) and App download wait:
    // backFile is only "peer finished sending", not "local file complete".
    if (recv.size > 0) {
      return (recv.size / 1024).clamp(90, 3600).toInt();
    }
    return 90;
  }

  /// Finalize a download recv slot. Safe if already completed / cancelled.
  Future<void> _finalizeRecv(
    DriveSession session,
    String key, {
    required bool ok,
    String error = '',
  }) async {
    await _drainChunkWrites(key);
    final recv = _recv.remove(key);
    if (recv == null) return;

    await _drainChunkWrites(key);

    final t = transferById(session, recv.transferId);
    if (t == null) {
      notifyListeners();
      return;
    }

    final bytes = await _recvLocalBytes(recv);
    recv.bytes = bytes;
    t.transferred = bytes;
    t.localPath = recv.path;
    if (t.size <= 0 && bytes > 0) t.size = bytes;
    if (recv.size > 0 && t.size < recv.size) t.size = recv.size;

    if (t.cancelRequested || t.status == DriveTransferStatus.cancelled) {
      t.status = DriveTransferStatus.cancelled;
      t.error = '已取消'.tr;
    } else if (!ok) {
      t.status = DriveTransferStatus.failed;
      if (error.isNotEmpty) {
        t.error = error;
      } else if (bytes <= 0) {
        t.error = '未收到文件数据（0 字节）'.tr;
      } else if (recv.size > 0 && bytes < recv.size) {
        t.error = AppL10n.current.fill(r'下载未收齐（$bytes / ${recv.size}）', {r'$bytes': '$bytes', r'${recv.size}': '${recv.size}'});
      } else {
        t.error = '下载失败'.tr;
      }
    } else if (bytes <= 0 && recv.size > 0) {
      t.status = DriveTransferStatus.failed;
      t.error = '未收到文件数据（0 字节）'.tr;
    } else {
      t.status = DriveTransferStatus.done;
      t.error = '';
    }

    if (t.startedAt != null && bytes > 0) {
      final elapsed =
          DateTime.now().difference(t.startedAt!).inMilliseconds.clamp(1, 1 << 30);
      t.speedBps = bytes * 1000 ~/ elapsed;
    }
    final c = _opWait.remove('dl:${t.id}');
    if (c != null && !c.isCompleted) {
      c.complete(t.status == DriveTransferStatus.done);
    }
    notifyListeners();
    if (t.status == DriveTransferStatus.done) {
      unawaited(_exportMediaToAlbumIfNeeded(t));
    }
  }

  /// After `backFile`: poll local cache until size matches or length stabilizes.
  /// Same idea as Desktop `wait_for_nas_cache` — never treat end signal as data done.
  Future<void> _settleRecvAfterBackFile(DriveSession session, String key) async {
    final recv = _recv[key];
    if (recv == null) return;
    recv.endSignaled = true;
    final epoch = ++recv.settleEpoch;
    final deadline =
        DateTime.now().add(Duration(seconds: _recvSettleSeconds(recv)));

    var lastLen = -1;
    var stable = 0;

    while (DateTime.now().isBefore(deadline)) {
      if (recv.settleEpoch != epoch) return;
      if (!identical(_recv[key], recv)) return;

      final t = transferById(session, recv.transferId);
      if (t == null ||
          t.cancelRequested ||
          t.status == DriveTransferStatus.cancelled) {
        return;
      }

      await _drainChunkWrites(key);
      if (!identical(_recv[key], recv)) return;

      final bytes = await _recvLocalBytes(recv);
      recv.bytes = bytes;
      t.transferred = bytes;
      t.localPath = recv.path;
      if (recv.size > 0) t.size = recv.size;
      if (t.startedAt != null && bytes > 0) {
        final elapsed = DateTime.now()
            .difference(t.startedAt!)
            .inMilliseconds
            .clamp(1, 1 << 30);
        t.speedBps = bytes * 1000 ~/ elapsed;
      }
      notifyListeners();

      final expected = recv.size > 0 ? recv.size : t.size;
      if (expected > 0 && bytes >= expected) {
        await _finalizeRecv(session, key, ok: true);
        return;
      }

      // Unknown size: require length to stay stable (~800ms), like Desktop.
      if (expected <= 0) {
        if (bytes > 0 && bytes == lastLen) {
          stable += 1;
          if (stable >= 8) {
            await _finalizeRecv(session, key, ok: true);
            return;
          }
        } else {
          stable = 0;
          lastLen = bytes;
        }
      }

      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    if (recv.settleEpoch != epoch || !identical(_recv[key], recv)) return;
    final bytes = await _recvLocalBytes(recv);
    final expected = recv.size > 0 ? recv.size : 0;
    final ok = expected > 0 ? bytes >= expected : bytes > 0;
    await _finalizeRecv(
      session,
      key,
      ok: ok,
      error: ok
          ? ''
          : (expected > 0
              ? AppL10n.current.fill(r'下载未收齐（$bytes / $expected）', {r'$bytes': '$bytes', r'$expected': '$expected'})
              : '下载超时或失败'.tr),
    );
  }

  Future<void> _onBackFile(DriveSession session, Map<String, dynamic> json) async {
    final name = safeFileName('${json['fileName'] ?? ''}');
    if (name.isEmpty) return;
    final key = '${session.rpcSessionId}::$name';

    // Yield so already-dispatched chunk listeners can register on the write chain.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await _drainChunkWrites(key);

    final recv = _recv[key];
    if (recv == null) {
      // Chunks may have already completed by size match; nothing left to settle.
      notifyListeners();
      return;
    }

    // Do NOT finalize here — SendFile/backFile can outrun P2P chunk delivery.
    unawaited(_settleRecvAfterBackFile(session, key));
  }

  void _onBackSearch(DriveSession session, Map<String, dynamic> json) {
    session.searching = false;
    session.searchError = json['ok'] == false ? '搜索失败'.tr : '';
    session.searchTruncated = json['truncated'] == true;
    final results = <NasSearchHit>[];
    final arr = json['results'];
    if (arr is List) {
      for (final item in arr) {
        if (item is! Map) continue;
        final name = '${item['name'] ?? ''}'.trim();
        if (name.isEmpty) continue;
        results.add(
          NasSearchHit(
            name: name,
            filePath: normalizeNasPath('${item['filePath'] ?? '/'}'),
            isDir: item['isDir'] == true,
          ),
        );
      }
    }
    session.searchHits = results;
    notifyListeners();
    ensureSearchThumbs(session, results);
  }

  Future<void> _onFileChunk(WebrpcFileChunkEvent event) async {
    if (!ownsRpc(event.sessionId)) return;
    final session = sessionByRpc(event.sessionId);
    if (session == null) return;
    final name = safeFileName(event.fileName);
    if (name.isEmpty) return;
    final key = '${event.sessionId}::$name';

    final previous = _chunkWriteChain[key] ?? Future<void>.value();
    final gate = Completer<void>();
    _chunkWriteChain[key] = gate.future;
    await previous;
    try {
      final recv = _recv[key];
      if (recv == null) return;
      final t = transferById(session, recv.transferId);
      if (t != null &&
          (t.cancelRequested || t.status == DriveTransferStatus.cancelled)) {
        recv.settleEpoch++;
        _recv.remove(key);
        final c = _opWait.remove('dl:${t.id}');
        if (c != null && !c.isCompleted) c.complete(false);
        t.status = DriveTransferStatus.cancelled;
        t.error = '已取消'.tr;
        notifyListeners();
        return;
      }
      final out = File(recv.path);
      if (recv.bytes == 0 && await out.exists()) {
        await out.delete();
      }
      await out.writeAsBytes(event.bytes, mode: FileMode.append, flush: true);
      recv.bytes += event.bytes.length;
      if (t != null) {
        t.transferred = recv.bytes;
        if (recv.size > 0) t.size = recv.size;
        if (t.startedAt != null) {
          final elapsed = DateTime.now()
              .difference(t.startedAt!)
              .inMilliseconds
              .clamp(1, 1 << 30);
          t.speedBps = recv.bytes * 1000 ~/ elapsed;
        }
        // Size known and fully written: finish without waiting for backFile.
        if (recv.size > 0 && recv.bytes >= recv.size) {
          recv.settleEpoch++;
          t.status = DriveTransferStatus.done;
          t.error = '';
          _recv.remove(key);
          final c = _opWait.remove('dl:${t.id}');
          if (c != null && !c.isCompleted) c.complete(true);
        }
        notifyListeners();
      }
    } finally {
      if (!gate.isCompleted) gate.complete();
      if (identical(_chunkWriteChain[key], gate.future)) {
        _chunkWriteChain.remove(key);
      }
    }
  }

  Future<String> _sliceFileFromOffset(String path, int offset) async {
    final src = File(path);
    final total = await src.length();
    if (offset <= 0 || offset >= total) return path;
    final dir = await _store.downloadDir(_ownerToken, '_tmp');
    final out = File(
      p.join(dir.path, 'put-slice-${_uuid.v4()}${p.extension(path)}'),
    );
    final raf = await src.open();
    try {
      await raf.setPosition(offset);
      final sink = out.openWrite();
      try {
        while (true) {
          final chunk = await raf.read(1024 * 1024);
          if (chunk.isEmpty) break;
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
    } finally {
      await raf.close();
    }
    return out.path;
  }

  void _ensureHeartbeat() {
    if (!_appForeground) return;
    if (_heartbeatTimer != null) return;
    _heartbeatTimer = Timer.periodic(DriveProtocol.heartbeatInterval, (_) {
      unawaited(_tickHeartbeat());
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  Future<void> _tickHeartbeat() async {
    if (!_appForeground || !_webrpc.isOnline) return;
    final connected =
        sessions.where((s) => s.connected && s.rpcSessionId != 0).toList();
    if (connected.isEmpty) {
      _stopHeartbeat();
      return;
    }
    for (final session in connected) {
      final t = DateTime.now().millisecondsSinceEpoch;
      _webrpc.sendJson(session.rpcSessionId, {
        'type': DriveProtocol.ping,
        'data': DriveProtocol.pingPayload(t),
      }, timeoutMs: 0);
      final misses = (_heartbeatMisses[session.id] ?? 0) + 1;
      _heartbeatMisses[session.id] = misses;
      if (misses >= DriveProtocol.heartbeatMissLimit) {
        AppDebugLog.log(
          'drive heartbeat: ${session.id} missed $misses → reconnect',
        );
        _heartbeatMisses[session.id] = 0;
        try {
          await forceReconnect(session);
        } catch (e) {
          AppDebugLog.log('drive heartbeat reconnect failed: $e');
        }
      }
    }
  }

  Future<void> _persist() async {
    if (_ownerToken.isEmpty) return;
    await _store.save(_ownerToken, sessions);
  }
}
