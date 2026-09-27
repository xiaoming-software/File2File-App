import 'dart:convert';

enum ChatMsgKind { text, image, video, audio, other }

enum ChatMsgStatus {
  sending,
  sent,
  failed,
  receiving,
  received,
}

ChatMsgKind classifyFileName(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.bmp') ||
      lower.endsWith('.heic')) {
    return ChatMsgKind.image;
  }
  if (lower.endsWith('.mp4') ||
      lower.endsWith('.mov') ||
      lower.endsWith('.mkv') ||
      lower.endsWith('.webm') ||
      lower.endsWith('.avi')) {
    return ChatMsgKind.video;
  }
  if (lower.endsWith('.mp3') ||
      lower.endsWith('.m4a') ||
      lower.endsWith('.aac') ||
      lower.endsWith('.wav') ||
      lower.endsWith('.flac') ||
      lower.endsWith('.ogg')) {
    return ChatMsgKind.audio;
  }
  return ChatMsgKind.other;
}

String safeFileName(String name) {
  var n = name.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
  if (n.isEmpty || n == '.' || n == '..') n = 'file';
  if (n.length > 180) {
    final dot = n.lastIndexOf('.');
    if (dot > 0 && n.length - dot <= 12) {
      final ext = n.substring(dot);
      n = '${n.substring(0, 180 - ext.length)}$ext';
    } else {
      n = n.substring(0, 180);
    }
  }
  return n;
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.fromMe,
    required this.kind,
    required this.content,
    required this.title,
    required this.time,
    required this.status,
    this.size = 0,
    this.transferred = 0,
    this.elapsedMs = 0,
    this.speedBps = 0,
    this.filePath = '',
  });

  final String id;
  final bool fromMe;
  ChatMsgKind kind;
  String content;
  String title;
  DateTime time;
  ChatMsgStatus status;
  int size;
  int transferred;
  int elapsedMs;
  int speedBps;
  String filePath;

  double get progress {
    if (size <= 0) return status == ChatMsgStatus.sent || status == ChatMsgStatus.received ? 1 : 0;
    return (transferred / size).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'from': fromMe ? 'me' : 'peer',
        'type': kind.name,
        'content': content,
        'title': title,
        'time': time.toIso8601String(),
        'status': status.name,
        'size': size,
        'transferred': transferred,
        'elapsedMs': elapsedMs,
        'speedBps': speedBps,
        'filePath': filePath,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final type = (json['type'] as String? ?? 'text').toLowerCase();
    final kind = ChatMsgKind.values.firstWhere(
      (k) => k.name == type,
      orElse: () => ChatMsgKind.text,
    );
    final statusName = (json['status'] as String? ?? 'sent').toLowerCase();
    final status = ChatMsgStatus.values.firstWhere(
      (s) => s.name == statusName,
      orElse: () => ChatMsgStatus.sent,
    );
    final timeRaw = json['time'];
    DateTime time;
    if (timeRaw is String) {
      time = DateTime.tryParse(timeRaw) ?? DateTime.now();
    } else if (timeRaw is num) {
      time = DateTime.fromMillisecondsSinceEpoch(timeRaw.toInt());
    } else {
      time = DateTime.now();
    }
    return ChatMessage(
      id: (json['id'] as String? ?? '').isEmpty
          ? DateTime.now().microsecondsSinceEpoch.toString()
          : json['id'] as String,
      fromMe: (json['from'] as String? ?? '') == 'me',
      kind: kind,
      content: json['content'] as String? ?? '',
      title: json['title'] as String? ?? '',
      time: time,
      status: status,
      size: (json['size'] as num?)?.toInt() ?? 0,
      transferred: (json['transferred'] as num?)?.toInt() ?? 0,
      elapsedMs: (json['elapsedMs'] as num?)?.toInt() ?? 0,
      speedBps: (json['speedBps'] as num?)?.toInt() ?? 0,
      filePath: json['filePath'] as String? ?? '',
    );
  }
}

class ChatSession {
  ChatSession({
    required this.id,
    required this.peerToken,
    this.remark = '',
    this.peerPass = '',
    this.connected = false,
    this.connecting = false,
    this.connectError = '',
    this.rpcSessionId = 0,
    List<ChatMessage>? messages,
  }) : messages = messages ?? <ChatMessage>[];

  final String id;
  String peerToken;
  String remark;
  String peerPass;
  bool connected;
  bool connecting;
  String connectError;
  int rpcSessionId;
  final List<ChatMessage> messages;

  String get displayTitle {
    final r = remark.trim();
    if (r.isNotEmpty) return r;
    final t = peerToken.trim();
    if (t.length <= 10) return t.isEmpty ? '未命名会话' : t;
    return '${t.substring(0, 6)}…${t.substring(t.length - 4)}';
  }

  String get subtitle {
    if (connecting) return '连接中…';
    if (connected) return '已连接 · $peerToken';
    if (connectError.isNotEmpty) return connectError;
    return peerToken;
  }

  ChatMessage? get lastMessage => messages.isEmpty ? null : messages.last;

  Map<String, dynamic> toMetaJson() => {
        'id': id,
        'peerToken': peerToken,
        'remark': remark,
        'peerPass': peerPass,
      };

  factory ChatSession.fromMetaJson(Map<String, dynamic> json) {
    return ChatSession(
      id: json['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
      peerToken: (json['peerToken'] as String? ?? '').trim(),
      remark: json['remark'] as String? ?? '',
      peerPass: json['peerPass'] as String? ?? '',
    );
  }
}

String formatBytes(int n) {
  final value = n < 0 ? 0 : n;
  String trim(double v) => v >= 10 ? v.toStringAsFixed(1) : v.toStringAsFixed(2);
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${trim(value / 1024)} KB';
  if (value < 1024 * 1024 * 1024) return '${trim(value / (1024 * 1024))} MB';
  return '${trim(value / (1024 * 1024 * 1024))} GB';
}

String formatSpeedBps(int bps) => '${formatBytes(bps)}/s';

String formatDurationMs(int ms) {
  final total = (ms < 0 ? 0 : ms) ~/ 1000;
  final m = total ~/ 60;
  final s = total % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// Desktop-compatible UTF-8 byte truncation (TITLE_MAX_BYTES = 30).
String truncateUtf8Bytes(String str, int maxBytes) {
  final units = <int>[];
  final buffer = StringBuffer();
  for (final rune in str.runes) {
    final ch = String.fromCharCode(rune);
    final next = utf8.encode(ch);
    if (units.length + next.length > maxBytes) {
      buffer.write('…');
      break;
    }
    units.addAll(next);
    buffer.write(ch);
  }
  return buffer.toString();
}
