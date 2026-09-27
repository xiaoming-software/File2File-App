import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/drive_models.dart';
import 'drive_store.dart';
import 'webrpc_service.dart';

class _RecvFile {
  _RecvFile({
    required this.transferId,
    required this.path,
    required this.size,
  });
  final String transferId;
  final String path;
  final int size;
  int bytes = 0;
}

/// Personal drive (mywebdisk-server) over webrpc string-typed NAS messages.
class DriveController extends ChangeNotifier {
  DriveController({
    required WebrpcService webrpc,
    DriveStore? store,
  })  : _webrpc = webrpc,
        _store = store ?? DriveStore();

  final WebrpcService _webrpc;
  final DriveStore _store;
  final _uuid = const Uuid();

  String _ownerToken = '';
  final List<DriveSession> sessions = [];
  bool loading = false;

  final Map<int, String> _pendingListPath = {};
  final Map<String, _RecvFile> _recv = {};
  final Map<String, Completer<bool>> _opWait = {};
  final Set<String> _uploadBusy = {};
  final Set<String> _downloadBusy = {};

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
    await unbind();
    _ownerToken = ownerToken.trim();
    loading = true;
    notifyListeners();
    try {
      sessions
        ..clear()
        ..addAll(await _store.load(_ownerToken));
      _dataSub = _webrpc.onData.listen(_onData);
      _fileSub = _webrpc.onFileChunk.listen(_onFileChunk);
      _statusSub = _webrpc.onStatus.listen((st) {
        if (st != WebrpcLoginState.online) {
          for (final s in sessions) {
            if (s.connected || s.connecting) {
              s.connected = false;
              s.connecting = false;
              s.rpcSessionId = 0;
              s.connectError = '已离线，请重新登录后连接';
              s.listing = false;
            }
          }
          _pendingListPath.clear();
          _recv.clear();
          _failAllWaiting('已离线');
          notifyListeners();
        }
      });
    } finally {
      loading = false;
      notifyListeners();
    }
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
    _failAllWaiting('已退出');
  }

  Future<DriveSession> createSession({
    required String peerToken,
    String peerPass = '',
    String remark = '',
  }) async {
    final peer = peerToken.trim();
    final pass = peerPass.trim();
    final note = remark.trim();
    if (peer.isEmpty) throw StateError('请填写网盘 Token');
    if (peer == _ownerToken) {
      throw StateError('不能使用当前登录 Token（webrpc 不支持自己连自己）');
    }
    if (sessions.any((s) => s.peerToken == peer)) {
      throw StateError('该网盘已存在');
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
      session.connectError = '请先登录 webrpc';
      notifyListeners();
      return;
    }
    if (session.peerToken == _ownerToken) {
      throw StateError('不能使用当前登录 Token（webrpc 不支持自己连自己）');
    }
    if (session.connecting || session.connected) return;
    session.connecting = true;
    session.connectError = '';
    notifyListeners();
    try {
      final rpcId = _webrpc.openSession(
        session.peerToken,
        permission: session.peerPass,
      );
      if (rpcId == 0) {
        throw StateError('连接失败（OpenSession=0），请检查网盘 Token、口令与在线状态');
      }
      final helloOk = _webrpc.sendJson(rpcId, {
        'type': 1,
        'data': {
          'sessionId': rpcId,
          'token': _webrpc.currentToken,
          'permission': _webrpc.currentPermission,
        },
      }, timeoutMs: 10000);
      if (!helloOk) {
        _webrpc.closeSession(rpcId);
        throw StateError('握手失败，请重试');
      }
      session.rpcSessionId = rpcId;
      session.connected = true;
      session.connecting = false;
      session.currentPath = '/';
      session.entries = [];
      await _persist();
      notifyListeners();
      requestNasInfo(session);
      await listPath(session, '/');
      unawaited(_pumpUploads(session));
      unawaited(_pumpDownloads(session));
    } catch (e) {
      session.connecting = false;
      session.connected = false;
      session.rpcSessionId = 0;
      session.connectError = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> disconnect(DriveSession session) async {
    final rpc = session.rpcSessionId;
    session.connected = false;
    session.connecting = false;
    session.rpcSessionId = 0;
    session.connectError = '';
    session.listing = false;
    session.entries = [];
    session.nasInfo = null;
    session.searching = false;
    if (rpc != 0) {
      _pendingListPath.remove(rpc);
      _recv.removeWhere((k, _) => k.startsWith('$rpc::'));
      try {
        _webrpc.closeSession(rpc);
      } catch (_) {}
    }
    _uploadBusy.remove(session.id);
    _downloadBusy.remove(session.id);
    notifyListeners();
  }

  Future<void> deleteSession(DriveSession session) async {
    await disconnect(session);
    sessions.removeWhere((s) => s.id == session.id);
    await _store.deleteDriveData(_ownerToken, session.peerToken);
    await _persist();
    notifyListeners();
  }

  void requestNasInfo(DriveSession session) {
    if (!session.connected || session.rpcSessionId == 0) return;
    _webrpc.sendJson(session.rpcSessionId, {'type': 'getNasInfo'}, timeoutMs: 10000);
  }

  Future<void> listPath(DriveSession session, String path) async {
    _ensureConnected(session);
    final dir = normalizeNasPath(path);
    session.listing = true;
    session.listError = '';
    session.listSeq += 1;
    final seq = session.listSeq;
    session.currentPath = dir;
    _pendingListPath[session.rpcSessionId] = dir;
    notifyListeners();
    final ok = _webrpc.sendJson(
      session.rpcSessionId,
      {'type': 'getPath', 'data': dir},
      timeoutMs: 15000,
    );
    if (!ok && session.listSeq == seq) {
      session.listing = false;
      session.listError = '列目录超时，请重试';
      notifyListeners();
    }
  }

  Future<void> refresh(DriveSession session) =>
      listPath(session, session.currentPath);

  Future<void> goUp(DriveSession session) =>
      listPath(session, parentNasPath(session.currentPath));

  Future<void> createFolder(DriveSession session, String name) async {
    _ensureConnected(session);
    final n = name.trim().replaceAll(RegExp(r'[\\/\x00]'), '');
    if (n.isEmpty || n == '.' || n == '..' || n.startsWith('.')) {
      throw StateError('文件夹名称无效');
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
      throw StateError('创建文件夹失败');
    }
    final success = await c.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _opWait.remove(key);
        return false;
      },
    );
    if (!success) throw StateError('创建文件夹失败');
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
      throw StateError('名称无效');
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
      throw StateError('重命名失败');
    }
    final success = await c.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _opWait.remove(key);
        return false;
      },
    );
    if (!success) throw StateError('重命名失败');
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
      throw StateError('删除失败');
    }
    final success = await c.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        _opWait.remove(key);
        return false;
      },
    );
    if (!success) throw StateError('删除失败');
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
    if (to == from) throw StateError('目标目录与当前相同');
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
      throw StateError('移动失败');
    }
    final success = await c.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        _opWait.remove(key);
        return false;
      },
    );
    if (!success) throw StateError('移动失败');
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
      session.searchError = '搜索超时';
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

  /// Queue downloads (serial).
  void enqueueDownloads(DriveSession session, List<NasEntry> entries) {
    _ensureConnected(session);
    for (final entry in entries) {
      if (entry.isDir) continue;
      final name = safeFileName(entry.name);
      session.transfers.insert(
        0,
        DriveTransfer(
          id: _uuid.v4(),
          kind: DriveTransferKind.download,
          name: name,
          remoteDir: session.currentPath,
          status: DriveTransferStatus.queued,
          size: entry.size,
        ),
      );
    }
    notifyListeners();
    unawaited(_pumpDownloads(session));
  }

  /// Start a download task and return immediately (does not wait for finish).
  DriveTransfer startDownload(
    DriveSession session,
    NasEntry entry, {
    String? remoteDir,
  }) {
    _ensureConnected(session);
    if (entry.isDir) throw StateError('不能下载目录');
    final t = DriveTransfer(
      id: _uuid.v4(),
      kind: DriveTransferKind.download,
      name: safeFileName(entry.name),
      remoteDir: remoteDir ?? session.currentPath,
      status: DriveTransferStatus.queued,
      size: entry.size,
    );
    session.transfers.insert(0, t);
    notifyListeners();
    unawaited(_pumpDownloads(session));
    return t;
  }

  Future<DriveTransfer> downloadNow(
    DriveSession session,
    NasEntry entry, {
    String? remoteDir,
  }) async {
    final t = startDownload(session, entry, remoteDir: remoteDir);
    // Wait until finished / failed.
    while (t.status == DriveTransferStatus.queued ||
        t.status == DriveTransferStatus.running) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (t.status == DriveTransferStatus.failed) {
      throw StateError(t.error.isEmpty ? '下载失败' : t.error);
    }
    return t;
  }

  Future<void> putTextFile(
    DriveSession session, {
    required String name,
    required String remoteDir,
    required String text,
  }) async {
    _ensureConnected(session);
    final safe = safeFileName(name);
    final tmpDir = await _store.downloadDir(_ownerToken, session.peerToken);
    final tmp = File(p.join(tmpDir.path, '.$safe.edit'));
    await tmp.writeAsString(text, flush: true);
    final size = await tmp.length();
    final announced = _webrpc.sendJson(
      session.rpcSessionId,
      {
        'type': 'putFile',
        'fileName': safe,
        'filePath': normalizeNasPath(remoteDir),
        'size': size,
      },
      timeoutMs: 15000,
    );
    if (!announced) throw StateError('保存失败');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final ok = size == 0
        ? true
        : await Future<bool>(() => _webrpc.sendFile(session.rpcSessionId, tmp.path));
    try {
      await tmp.delete();
    } catch (_) {}
    if (!ok) throw StateError('保存失败');
    if (normalizeNasPath(remoteDir) == session.currentPath) {
      await refresh(session);
    }
  }

  Future<void> retryTransfer(DriveSession session, DriveTransfer t) async {
    if (t.status != DriveTransferStatus.failed) return;
    t.status = DriveTransferStatus.queued;
    t.error = '';
    t.transferred = 0;
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
          t.status == DriveTransferStatus.failed,
    );
    notifyListeners();
  }

  void removeTask(DriveSession session, DriveTransfer t) {
    if (t.status == DriveTransferStatus.running) return;
    session.transfers.removeWhere((e) => e.id == t.id);
    notifyListeners();
  }

  DriveTransfer? transferById(DriveSession session, String id) {
    for (final t in session.transfers) {
      if (t.id == id) return t;
    }
    return null;
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
        throw StateError('本地文件不存在');
      }
      final size = await File(path).length();
      t.size = size;
      final announced = _webrpc.sendJson(
        session.rpcSessionId,
        {
          'type': 'putFile',
          'fileName': t.name,
          'filePath': t.remoteDir,
          'size': size,
        },
        timeoutMs: 15000,
      );
      if (!announced) throw StateError('上传宣告失败');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (size == 0) {
        t.transferred = 0;
        t.status = DriveTransferStatus.done;
      } else {
        final ok = await Future<bool>(
          () => _webrpc.sendFile(session.rpcSessionId, path),
        );
        if (!ok) throw StateError('SendFile 失败');
        t.transferred = size;
        t.status = DriveTransferStatus.done;
        final elapsed =
            DateTime.now().difference(t.startedAt!).inMilliseconds.clamp(1, 1 << 30);
        t.speedBps = size * 1000 ~/ elapsed;
      }
      notifyListeners();
      if (t.remoteDir == session.currentPath) {
        await refresh(session);
      }
    } catch (e) {
      t.status = DriveTransferStatus.failed;
      t.error = e.toString();
      notifyListeners();
    }
  }

  Future<void> _runDownload(DriveSession session, DriveTransfer t) async {
    t.status = DriveTransferStatus.running;
    t.startedAt = DateTime.now();
    t.error = '';
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
      if (await f.exists()) await f.delete();
      if (t.size == 0) {
        await f.writeAsBytes(const []);
        t.status = DriveTransferStatus.done;
        t.transferred = 0;
        notifyListeners();
        return;
      }
      final key = '${session.rpcSessionId}::${t.name}';
      final done = Completer<bool>();
      _recv[key] = _RecvFile(transferId: t.id, path: local, size: t.size);
      _opWait['dl:${t.id}'] = done;
      final ok = _webrpc.sendJson(
        session.rpcSessionId,
        {
          'type': 'getFile',
          'fileName': t.name,
          'filePath': t.remoteDir,
        },
        timeoutMs: 15000,
      );
      if (!ok) {
        _recv.remove(key);
        _opWait.remove('dl:${t.id}');
        throw StateError('请求下载失败');
      }
      final success = await done.future.timeout(
        Duration(seconds: (t.size / 1024).clamp(60, 3600).toInt()),
        onTimeout: () {
          _recv.remove(key);
          _opWait.remove('dl:${t.id}');
          return t.status == DriveTransferStatus.done;
        },
      );
      if (!success && t.status != DriveTransferStatus.done) {
        throw StateError('下载超时或失败');
      }
      if (t.status == DriveTransferStatus.running) {
        t.status = DriveTransferStatus.done;
      }
      notifyListeners();
    } catch (e) {
      t.status = DriveTransferStatus.failed;
      t.error = e.toString();
      notifyListeners();
    }
  }

  void _ensureConnected(DriveSession session) {
    if (!session.connected || session.rpcSessionId == 0) {
      throw StateError('网盘未连接');
    }
    if (!_webrpc.isOnline) {
      throw StateError('webrpc 未登录');
    }
  }

  void _onData(WebrpcDataEvent event) {
    if (!ownsRpc(event.sessionId)) return;
    final bytes = event.bytes;
    if (bytes.length >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0) {
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
    if (type is! String) return;
    final session = sessionByRpc(event.sessionId);
    if (session == null) return;
    switch (type) {
      case 'backNasInfo':
        final data = json['data'];
        if (data is Map) {
          session.nasInfo = NasInfo.fromJson(Map<String, dynamic>.from(data));
          notifyListeners();
        }
        break;
      case 'backPath':
        _onBackPath(session, json);
        break;
      case 'backFile':
        _onBackFile(session, json);
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

  void _onBackPath(DriveSession session, Map<String, dynamic> json) {
    final reported = '${json['path'] ?? ''}';
    final queued = _pendingListPath.remove(session.rpcSessionId);
    final path = reported.trim().isEmpty
        ? (queued ?? session.currentPath)
        : normalizeNasPath(reported);
    final data = json['data'];
    final entries = <NasEntry>[];
    if (data is Map) {
      data.forEach((key, value) {
        final name = '$key';
        if (name.isEmpty || name.startsWith('.')) return;
        if (value is Map) {
          entries.add(
            NasEntry.fromPathItem(name, Map<String, dynamic>.from(value)),
          );
        }
      });
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    session.currentPath = path;
    session.entries = entries;
    session.listing = false;
    session.listError = '';
    notifyListeners();
  }

  void _onBackFile(DriveSession session, Map<String, dynamic> json) {
    final name = safeFileName('${json['fileName'] ?? ''}');
    if (name.isEmpty) return;
    final key = '${session.rpcSessionId}::$name';
    final recv = _recv.remove(key);
    DriveTransfer? t;
    if (recv != null) {
      t = transferById(session, recv.transferId);
      if (t != null) {
        t.transferred = recv.bytes;
        t.localPath = recv.path;
        t.status = DriveTransferStatus.done;
        if (t.startedAt != null) {
          final elapsed =
              DateTime.now().difference(t.startedAt!).inMilliseconds.clamp(1, 1 << 30);
          t.speedBps = recv.bytes * 1000 ~/ elapsed;
        }
        final c = _opWait.remove('dl:${t.id}');
        if (c != null && !c.isCompleted) c.complete(true);
      }
    }
    notifyListeners();
  }

  void _onBackSearch(DriveSession session, Map<String, dynamic> json) {
    session.searching = false;
    session.searchError = json['ok'] == false ? '搜索失败' : '';
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
  }

  Future<void> _onFileChunk(WebrpcFileChunkEvent event) async {
    if (!ownsRpc(event.sessionId)) return;
    final session = sessionByRpc(event.sessionId);
    if (session == null) return;
    final name = safeFileName(event.fileName);
    if (name.isEmpty) return;
    final key = '${event.sessionId}::$name';
    final recv = _recv[key];
    if (recv == null) return;
    final out = File(recv.path);
    if (recv.bytes == 0 && await out.exists()) {
      await out.delete();
    }
    await out.writeAsBytes(event.bytes, mode: FileMode.append, flush: true);
    recv.bytes += event.bytes.length;
    final t = transferById(session, recv.transferId);
    if (t != null) {
      t.transferred = recv.bytes;
      if (recv.size > 0) t.size = recv.size;
      if (t.startedAt != null) {
        final elapsed =
            DateTime.now().difference(t.startedAt!).inMilliseconds.clamp(1, 1 << 30);
        t.speedBps = recv.bytes * 1000 ~/ elapsed;
      }
      if (recv.size > 0 && recv.bytes >= recv.size) {
        t.status = DriveTransferStatus.done;
        _recv.remove(key);
        final c = _opWait.remove('dl:${t.id}');
        if (c != null && !c.isCompleted) c.complete(true);
      }
      notifyListeners();
    }
  }

  Future<void> _persist() async {
    if (_ownerToken.isEmpty) return;
    await _store.save(_ownerToken, sessions);
  }
}
