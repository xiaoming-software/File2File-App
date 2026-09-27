import 'dart:convert';

import '../models/chat_models.dart' show ChatMsgKind, classifyFileName;

export 'chat_models.dart' show ChatMsgKind, classifyFileName, safeFileName;

enum DrivePreviewKind { none, text, image, audio, video }

DrivePreviewKind drivePreviewKind(String name) {
  final kind = classifyFileName(name);
  switch (kind) {
    case ChatMsgKind.image:
      return DrivePreviewKind.image;
    case ChatMsgKind.video:
      return DrivePreviewKind.video;
    case ChatMsgKind.audio:
      return DrivePreviewKind.audio;
    case ChatMsgKind.text:
    case ChatMsgKind.other:
      break;
  }
  final lower = name.toLowerCase();
  const textExts = {
    '.txt',
    '.md',
    '.markdown',
    '.json',
    '.xml',
    '.csv',
    '.log',
    '.yaml',
    '.yml',
    '.ini',
    '.conf',
    '.html',
    '.htm',
    '.css',
    '.js',
    '.ts',
    '.dart',
    '.py',
    '.go',
    '.rs',
    '.java',
    '.kt',
    '.c',
    '.cpp',
    '.h',
    '.hpp',
    '.sh',
    '.sql',
  };
  for (final e in textExts) {
    if (lower.endsWith(e)) return DrivePreviewKind.text;
  }
  return DrivePreviewKind.none;
}

class NasEntry {
  NasEntry({
    required this.name,
    required this.isDir,
    this.size = 0,
    this.lastDateMs = 0,
  });

  final String name;
  final bool isDir;
  final int size;
  final int lastDateMs;

  DrivePreviewKind get previewKind =>
      isDir ? DrivePreviewKind.none : drivePreviewKind(name);

  factory NasEntry.fromPathItem(String name, Map<String, dynamic> item) {
    final ifFile = item['ifFile'] == true || item['ifFile'] == 1;
    final sizeRaw = item['size'];
    final size = sizeRaw is num ? sizeRaw.toInt() : 0;
    final lastRaw = item['lastDate'];
    final last = lastRaw is num ? lastRaw.toInt() : 0;
    return NasEntry(
      name: name,
      isDir: !ifFile,
      size: ifFile ? (size < 0 ? 0 : size) : 0,
      lastDateMs: last,
    );
  }
}

class NasInfo {
  const NasInfo({
    this.diskSize = 0,
    this.banlenSize = 0,
    this.fileNum = 0,
  });

  final int diskSize;
  final int banlenSize;
  final int fileNum;

  factory NasInfo.fromJson(Map<String, dynamic> json) {
    int n(dynamic v) => v is num ? v.toInt() : 0;
    return NasInfo(
      diskSize: n(json['diskSize']),
      banlenSize: n(json['banlenSize']),
      fileNum: n(json['fileNum']),
    );
  }
}

class NasSearchHit {
  NasSearchHit({
    required this.name,
    required this.filePath,
    required this.isDir,
  });

  final String name;
  final String filePath;
  final bool isDir;
}

enum DriveTransferKind { download, upload }

enum DriveTransferStatus { queued, running, done, failed }

class DriveTransfer {
  DriveTransfer({
    required this.id,
    required this.kind,
    required this.name,
    required this.remoteDir,
    required this.status,
    this.size = 0,
    this.transferred = 0,
    this.localPath = '',
    this.error = '',
    this.startedAt,
    this.speedBps = 0,
  });

  final String id;
  final DriveTransferKind kind;
  final String name;
  final String remoteDir;
  DriveTransferStatus status;
  int size;
  int transferred;
  String localPath;
  String error;
  DateTime? startedAt;
  int speedBps;

  double get progress {
    if (size <= 0) return status == DriveTransferStatus.done ? 1 : 0;
    final p = transferred / size;
    if (p < 0) return 0;
    if (p > 1) return 1;
    return p;
  }
}

class DriveSession {
  DriveSession({
    required this.id,
    required this.peerToken,
    this.peerPass = '',
    this.remark = '',
  });

  final String id;
  String peerToken;
  String peerPass;
  String remark;

  int rpcSessionId = 0;
  bool connected = false;
  bool connecting = false;
  String connectError = '';

  String currentPath = '/';
  List<NasEntry> entries = [];
  bool listing = false;
  String listError = '';
  int listSeq = 0;
  NasInfo? nasInfo;

  final List<DriveTransfer> transfers = [];

  bool searching = false;
  String searchKeyword = '';
  List<NasSearchHit> searchHits = [];
  String searchError = '';
  bool searchTruncated = false;

  int get activeTaskCount => transfers
      .where((t) =>
          t.status == DriveTransferStatus.queued ||
          t.status == DriveTransferStatus.running)
      .length;

  String get displayTitle {
    final r = remark.trim();
    if (r.isNotEmpty) return r;
    final t = peerToken.trim();
    if (t.length <= 12) return t.isEmpty ? '网盘' : t;
    return '${t.substring(0, 6)}…${t.substring(t.length - 4)}';
  }

  Map<String, dynamic> toMetaJson() => {
        'id': id,
        'peerToken': peerToken,
        'peerPass': peerPass,
        'remark': remark,
      };

  factory DriveSession.fromMetaJson(Map<String, dynamic> json) {
    return DriveSession(
      id: '${json['id'] ?? ''}'.trim().isEmpty
          ? DateTime.now().millisecondsSinceEpoch.toString()
          : '${json['id']}',
      peerToken: '${json['peerToken'] ?? ''}'.trim(),
      peerPass: '${json['peerPass'] ?? ''}'.trim(),
      remark: '${json['remark'] ?? ''}'.trim(),
    );
  }
}

String normalizeNasPath(String raw) {
  final cleaned = raw.replaceAll('\\', '/');
  final parts = <String>[];
  for (final part in cleaned.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    if (part.startsWith('.')) continue;
    parts.add(part);
  }
  if (parts.isEmpty) return '/';
  return '/${parts.join('/')}';
}

String joinNasPath(String dir, String name) {
  final d = normalizeNasPath(dir);
  final n = name.trim();
  if (n.isEmpty) return d;
  if (d == '/') return '/$n';
  return '$d/$n';
}

String parentNasPath(String path) {
  final n = normalizeNasPath(path);
  if (n == '/') return '/';
  final i = n.lastIndexOf('/');
  if (i <= 0) return '/';
  return n.substring(0, i);
}

String formatBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  if (n < 1024 * 1024 * 1024) {
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String encodeDriveList(List<DriveSession> sessions) {
  return const JsonEncoder.withIndent('  ')
      .convert(sessions.map((s) => s.toMetaJson()).toList());
}
