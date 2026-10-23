import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../models/drive_models.dart';
import 'drive_store.dart';
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
  final Map<int, Completer<_PutAck>> _putWait = {};
  final Map<int, _ListWait> _verifyList = {};
  final Map<String, _RecvFile> _recv = {};
  final Map<String, Completer<bool>> _opWait = {};
  final Map<String, Future<void>> _chunkWriteChain = {};
  final Set<String> _uploadBusy = {};
  final Set<String> _downloadBusy = {};

  /// sessionId::dir::name -> local jpeg path
  final Map<String, String> _thumbPaths = {};
  final Set<String> _thumbPending = {};
  final Set<String> _thumbFailed = {};
  static const thumbEdge = 192;

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
  Future<DriveTransfer> startDownload(
    DriveSession session,
    NasEntry entry, {
    String? remoteDir,
    bool forPreview = false,
  }) async {
    _ensureConnected(session);
    if (entry.isDir) throw StateError('不能下载目录');
    final dir = normalizeNasPath(remoteDir ?? session.currentPath);
    final name = safeFileName(entry.name);

    final existing = session.findDownload(dir, name);
    if (existing != null) {
      if (existing.status == DriveTransferStatus.queued ||
          existing.status == DriveTransferStatus.running) {
        if (entry.size > 0 && existing.size <= 0) existing.size = entry.size;
        // Shared with another opener — do not cancel when one preview closes.
        existing.cancelableByPreview = false;
        return existing;
      }
      if (existing.status == DriveTransferStatus.done &&
          await _isLocalComplete(existing, entry.size)) {
        if (entry.size > 0) existing.size = entry.size;
        existing.cancelableByPreview = false;
        return existing;
      }
      // Failed / cancelled / done-but-empty stub: reuse the same task slot.
      if (existing.localPath.isNotEmpty) {
        try {
          final f = File(existing.localPath);
          if (await f.exists()) {
            final len = await f.length();
            final ok = entry.size > 0 ? len >= entry.size : len > 0;
            if (!ok) await f.delete();
          }
        } catch (_) {}
      }
      existing.status = DriveTransferStatus.queued;
      existing.size = entry.size;
      existing.transferred = 0;
      existing.localPath = '';
      existing.error = '';
      existing.cancelRequested = false;
      existing.cancelableByPreview = forPreview;
      existing.speedBps = 0;
      existing.startedAt = null;
      notifyListeners();
      unawaited(_pumpDownloads(session));
      return existing;
    }

    // Only reuse orphan local files when listing size is known and matches.
    // size==0 in listings is common for txt; never treat empty stubs as complete.
    if (entry.size > 0) {
      final local =
          await _store.downloadPath(_ownerToken, session.peerToken, name);
      final localFile = File(local);
      if (await localFile.exists()) {
        final len = await localFile.length();
        if (len >= entry.size) {
          if (existing != null &&
              (existing.status == DriveTransferStatus.failed ||
                  existing.status == DriveTransferStatus.cancelled ||
                  existing.status == DriveTransferStatus.done)) {
            existing.status = DriveTransferStatus.done;
            existing.localPath = local;
            existing.transferred = len;
            existing.size = entry.size;
            existing.error = '';
            existing.cancelRequested = false;
            existing.cancelableByPreview = false;
            notifyListeners();
            return existing;
          }
          final done = DriveTransfer(
            id: _uuid.v4(),
            kind: DriveTransferKind.download,
            name: name,
            remoteDir: dir,
            status: DriveTransferStatus.done,
            size: entry.size,
            transferred: len,
            localPath: local,
          );
          session.transfers.insert(0, done);
          notifyListeners();
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
    final t = await startDownload(session, entry, remoteDir: remoteDir);
    while (t.status == DriveTransferStatus.queued ||
        t.status == DriveTransferStatus.running) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (t.status == DriveTransferStatus.failed ||
        t.status == DriveTransferStatus.cancelled) {
      throw StateError(t.error.isEmpty ? '下载失败' : t.error);
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
      t.error = '已取消';
      t.cancelRequested = false;
      notifyListeners();
      return;
    }
    if (t.status != DriveTransferStatus.running) return;
    t.cancelRequested = true;
    t.error = '已取消';
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
    final tmpDir = await _store.downloadDir(_ownerToken, session.peerToken);
    final tmp = File(p.join(tmpDir.path, '.$safe.edit'));
    await tmp.writeAsString(text, flush: true);
    try {
      await _putLocalFile(
        session,
        localPath: tmp.path,
        name: safe,
        remoteDir: normalizeNasPath(remoteDir),
      );
    } finally {
      try {
        await tmp.delete();
      } catch (_) {}
    }
    if (normalizeNasPath(remoteDir) == session.currentPath) {
      await refresh(session);
    }
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

  /// Ask server for missing image/video thumbnails (idempotent, rate-limited by pending set).
  void ensureThumbs(
    DriveSession session,
    Iterable<NasEntry> entries, {
    String? remoteDir,
  }) {
    if (!session.connected || session.rpcSessionId == 0) return;
    final dir = normalizeNasPath(remoteDir ?? session.currentPath);
    for (final entry in entries) {
      if (entry.isDir) continue;
      final kind = entry.previewKind;
      if (kind != DrivePreviewKind.image && kind != DrivePreviewKind.video) {
        continue;
      }
      final key = thumbCacheKey(session, dir, entry.name);
      if (_thumbPaths.containsKey(key) ||
          _thumbPending.contains(key) ||
          _thumbFailed.contains(key)) {
        continue;
      }
      _thumbPending.add(key);
      unawaited(_requestThumb(session, dir, entry.name, key));
    }
  }

  Future<void> _requestThumb(
    DriveSession session,
    String dir,
    String name,
    String key,
  ) async {
    try {
      final cached = await _store.thumbPath(
        _ownerToken,
        session.peerToken,
        dir,
        name,
        edge: thumbEdge,
      );
      if (await File(cached).exists() && await File(cached).length() > 0) {
        _thumbPaths[key] = cached;
        _thumbPending.remove(key);
        notifyListeners();
        return;
      }
    } catch (_) {}
    if (!session.connected || session.rpcSessionId == 0) {
      _thumbPending.remove(key);
      return;
    }
    final ok = _webrpc.sendJson(
      session.rpcSessionId,
      {
        'type': 'getThumb',
        'fileName': name,
        'filePath': dir,
        'maxEdge': thumbEdge,
      },
      timeoutMs: 15000,
    );
    if (!ok) {
      _thumbPending.remove(key);
      _thumbFailed.add(key);
      notifyListeners();
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
    _thumbPending.remove(key);
    final ok = json['ok'] == true;
    final dataB64 = '${json['data'] ?? ''}';
    if (!ok || dataB64.isEmpty) {
      _thumbFailed.add(key);
      notifyListeners();
      return;
    }
    try {
      final bytes = base64Decode(dataB64);
      if (bytes.isEmpty) {
        _thumbFailed.add(key);
        notifyListeners();
        return;
      }
      final path = await _store.thumbPath(
        _ownerToken,
        session.peerToken,
        dir,
        name,
        edge: thumbEdge,
      );
      await File(path).writeAsBytes(bytes, flush: true);
      _thumbPaths[key] = path;
      _thumbFailed.remove(key);
      notifyListeners();
    } catch (_) {
      _thumbFailed.add(key);
      notifyListeners();
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
        throw StateError('本地文件不存在');
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
      t.status = DriveTransferStatus.failed;
      t.error = e.toString();
      notifyListeners();
    }
  }

  Future<void> _runDownload(DriveSession session, DriveTransfer t) async {
    if (t.cancelRequested || t.status == DriveTransferStatus.cancelled) {
      t.status = DriveTransferStatus.cancelled;
      t.error = t.error.isEmpty ? '已取消' : t.error;
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
      if (await f.exists()) {
        final len = await f.length();
        // Only skip network when listing size is known and local file matches.
        if (t.size > 0 && len >= t.size) {
          t.transferred = len;
          t.status = DriveTransferStatus.done;
          notifyListeners();
          return;
        }
        await f.delete();
      }
      // IMPORTANT: size==0 often means "unknown" (common for txt), NOT empty.
      // Always request getFile; completion comes from chunks / backFile.
      if (t.cancelRequested) {
        t.status = DriveTransferStatus.cancelled;
        t.error = '已取消';
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
        t.error = '已取消';
        notifyListeners();
        return;
      }
      if (!success && t.status != DriveTransferStatus.done) {
        final detail = t.error.trim();
        throw StateError(detail.isEmpty ? '下载超时或失败' : detail);
      }
      if (t.status == DriveTransferStatus.running) {
        t.status = DriveTransferStatus.done;
      }
      notifyListeners();
    } catch (e) {
      if (t.cancelRequested || t.status == DriveTransferStatus.cancelled) {
        t.status = DriveTransferStatus.cancelled;
        t.error = '已取消';
      } else {
        t.status = DriveTransferStatus.failed;
        t.error = e.toString();
      }
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
      t.transferred = written;
      final started = t.startedAt;
      if (started != null && written > 0) {
        final ms = DateTime.now().difference(started).inMilliseconds.clamp(1, 1 << 30);
        t.speedBps = written * 1000 ~/ ms;
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
    notifyListeners();
    // Prefetch thumbs for media in this directory (server generates/caches).
    ensureThumbs(session, entries);
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
    if (task != null) {
      task.size = size;
      task.transferred = 0;
      notifyListeners();
    }
    final ackWait = Completer<_PutAck>();
    _putWait[rpc] = ackWait;
    final announced = _webrpc.sendJson(
      rpc,
      {
        'type': 'putFile',
        'fileName': name,
        'filePath': dir,
        'size': size,
      },
      timeoutMs: 15000,
    );
    if (!announced) {
      _putWait.remove(rpc);
      throw StateError('上传宣告失败');
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
    try {
      if (size > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await _webrpc.sendFileAsync(rpc, localPath);
      }
    } finally {
      tick?.cancel();
    }
    final ack = ackWait.isCompleted
        ? await ackWait.future
        : await ackWait.future.timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              _putWait.remove(rpc);
              return _PutAck(
                written: task?.transferred ?? 0,
                size: size,
                ok: false,
                error: '上传未确认完成',
              );
            },
          );
    if (!ack.ok || ack.written != size) {
      await _deleteRemoteQuiet(session, dir, name);
      final why = ack.error.isEmpty ? '字节数不一致' : ack.error;
      throw StateError('上传校验失败: $why');
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
        listErr = StateError('目录大小 $listed 与本地 $size 不一致');
      } catch (e) {
        listErr = e;
      }
    }
    final msg = '$listErr';
    if (!msg.contains('超时')) {
      await _deleteRemoteQuiet(session, dir, name);
    }
    throw StateError('目录核对失败: $msg');
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
      throw StateError('目录核对超时');
    }
    final entries = await wait.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        _verifyList.remove(rpc);
        throw StateError('目录核对超时');
      },
    );
    for (final entry in entries) {
      if (!entry.isDir && entry.name == name) return entry.size;
    }
    throw StateError('目录中没有该文件');
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
      t.error = '已取消';
    } else if (!ok) {
      t.status = DriveTransferStatus.failed;
      if (error.isNotEmpty) {
        t.error = error;
      } else if (bytes <= 0) {
        t.error = '未收到文件数据（0 字节）';
      } else if (recv.size > 0 && bytes < recv.size) {
        t.error = '下载未收齐（$bytes / ${recv.size}）';
      } else {
        t.error = '下载失败';
      }
    } else if (bytes <= 0 && recv.size > 0) {
      t.status = DriveTransferStatus.failed;
      t.error = '未收到文件数据（0 字节）';
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
              ? '下载未收齐（$bytes / $expected）'
              : '下载超时或失败'),
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
        t.error = '已取消';
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

  Future<void> _persist() async {
    if (_ownerToken.isEmpty) return;
    await _store.save(_ownerToken, sessions);
  }
}
