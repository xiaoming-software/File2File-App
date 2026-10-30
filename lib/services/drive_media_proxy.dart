import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'webrpc_service.dart';

/// Local HTTP proxy that streams drive video/audio via webrpc statFile/readRange.
///
/// Lifecycle matches the drive session: start after first successful list;
/// stop when the session closes. webrpc reconnects do not tear down the listener.
class DriveMediaProxy {
  DriveMediaProxy(this._webrpc);

  final WebrpcService _webrpc;

  HttpServer? _server;
  int _port = 0;
  String _token = '';
  int _rpcSessionId = 0;
  bool _started = false;

  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  int _reqSeq = 0;

  static const _maxChunk = 1 << 20;
  static const _readTimeout = Duration(seconds: 10);

  bool get isRunning => _started && _server != null;
  int get port => _port;
  String get token => _token;
  String get baseUrl => 'http://127.0.0.1:$_port';

  /// Idempotent: bind 127.0.0.1 and serve /media/{token}/...
  Future<void> ensureStarted(int rpcSessionId) async {
    if (rpcSessionId == 0) return;
    _rpcSessionId = rpcSessionId;
    if (_started && _server != null) return;
    _token = _newToken(rpcSessionId);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _port = server.port;
    _started = true;
    debugPrint('drive media proxy up port=$_port');
    server.listen(_onRequest, onError: (Object e) {
      debugPrint('drive media proxy listen error: $e');
    });
  }

  Future<void> stop() async {
    _started = false;
    final s = _server;
    _server = null;
    _port = 0;
    _token = '';
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('proxy stopped'));
      }
    }
    _pending.clear();
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
  }

  /// Update rpc id after webrpc rebind without restarting the listener.
  void bindRpc(int rpcSessionId) {
    if (rpcSessionId != 0) _rpcSessionId = rpcSessionId;
  }

  String? streamUrl(String remoteDir, String fileName) {
    if (!isRunning || _token.isEmpty) return null;
    final path = _joinNasPath(remoteDir, fileName);
    final enc = path
        .split('/')
        .where((s) => s.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    return '$baseUrl/media/$_token/$enc';
  }

  void onBackStat(Map<String, dynamic> json) => _fulfill(json);
  void onBackRange(Map<String, dynamic> json) => _fulfill(json);

  void _fulfill(Map<String, dynamic> json) {
    final rid = ('${json['requestId'] ?? ''}').trim();
    if (rid.isEmpty) return;
    final c = _pending.remove(rid);
    if (c != null && !c.isCompleted) c.complete(json);
  }

  Future<void> _onRequest(HttpRequest req) async {
    try {
      req.response.headers.set('Access-Control-Allow-Origin', '*');
      req.response.headers.set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS');
      req.response.headers.set(
        'Access-Control-Expose-Headers',
        'Content-Range, Accept-Ranges, Content-Length',
      );
      if (req.method == 'OPTIONS') {
        req.response.statusCode = HttpStatus.noContent;
        await req.response.close();
        return;
      }
      if (req.method != 'GET' && req.method != 'HEAD') {
        req.response.statusCode = HttpStatus.methodNotAllowed;
        await req.response.close();
        return;
      }
      final segs = req.uri.pathSegments;
      if (segs.length < 3 || segs[0] != 'media') {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      if (segs[1] != _token) {
        req.response.statusCode = HttpStatus.forbidden;
        await req.response.close();
        return;
      }
      final nasPath = segs.sublist(2).map(Uri.decodeComponent).join('/');
      final parts = _splitNasPath(nasPath);
      final filePath = parts.$1;
      final fileName = parts.$2;
      if (fileName.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        await req.response.close();
        return;
      }

      final stat = await _rpcStat(filePath, fileName);
      if (stat == null || stat['ok'] != true) {
        req.response.statusCode =
            stat == null ? HttpStatus.serviceUnavailable : HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final size = (stat['size'] as num?)?.toInt() ?? 0;
      final mime = ('${stat['mime'] ?? 'application/octet-stream'}');

      final rangeHdr = req.headers.value(HttpHeaders.rangeHeader);
      final range = _parseRange(rangeHdr, size);
      if (range == null && rangeHdr != null) {
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        req.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        await req.response.close();
        return;
      }
      final start = range?.$1 ?? 0;
      final endIncl = range?.$2 ?? (size > 0 ? size - 1 : 0);
      final length = size == 0 ? 0 : (endIncl - start + 1);

      req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      req.response.headers.contentType = ContentType.parse(mime);
      if (rangeHdr != null && size > 0) {
        req.response.statusCode = HttpStatus.partialContent;
        req.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$endIncl/$size',
        );
      } else {
        req.response.statusCode = HttpStatus.ok;
      }
      req.response.contentLength = length;

      if (req.method == 'HEAD' || length <= 0) {
        await req.response.close();
        return;
      }

      var off = start;
      while (off <= endIncl) {
        final remain = endIncl - off + 1;
        final chunk = remain < _maxChunk ? remain : _maxChunk;
        final bytes = await _rpcRead(filePath, fileName, off, chunk);
        if (bytes == null) {
          if (off == start) {
            req.response.statusCode = HttpStatus.serviceUnavailable;
          }
          break;
        }
        if (bytes.isEmpty) break;
        req.response.add(bytes);
        off += bytes.length;
        if (bytes.length < chunk) break;
      }
      await req.response.close();
    } catch (e, st) {
      debugPrint('drive media proxy request failed: $e\n$st');
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<Map<String, dynamic>?> _rpcStat(String filePath, String fileName) async {
    final rid = _nextId();
    final c = Completer<Map<String, dynamic>>();
    _pending[rid] = c;
    final ok = _webrpc.sendJson(_rpcSessionId, {
      'type': 'statFile',
      'fileName': fileName,
      'filePath': filePath,
      'requestId': rid,
    }, timeoutMs: 10000);
    if (!ok) {
      _pending.remove(rid);
      return null;
    }
    try {
      return await c.future.timeout(_readTimeout);
    } catch (_) {
      _pending.remove(rid);
      return null;
    }
  }

  Future<Uint8List?> _rpcRead(
    String filePath,
    String fileName,
    int offset,
    int length,
  ) async {
    final rid = _nextId();
    final c = Completer<Map<String, dynamic>>();
    _pending[rid] = c;
    final ok = _webrpc.sendJson(_rpcSessionId, {
      'type': 'readRange',
      'fileName': fileName,
      'filePath': filePath,
      'offset': offset,
      'length': length,
      'requestId': rid,
    }, timeoutMs: 10000);
    if (!ok) {
      _pending.remove(rid);
      return null;
    }
    try {
      final json = await c.future.timeout(_readTimeout);
      if (json['ok'] != true) return null;
      final b64 = '${json['data'] ?? ''}';
      if (b64.isEmpty) return Uint8List(0);
      return Uint8List.fromList(base64Decode(b64));
    } catch (_) {
      _pending.remove(rid);
      return null;
    }
  }

  String _nextId() {
    _reqSeq += 1;
    return 'r$_rpcSessionId-$_reqSeq-${DateTime.now().microsecondsSinceEpoch}';
  }

  static String _newToken(int rpc) {
    final r = Random.secure();
    final n = List.generate(8, (_) => r.nextInt(256));
    return '${rpc.toRadixString(16).padLeft(8, '0')}'
        '${n.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  static String _joinNasPath(String dir, String name) {
    final d = dir.trim().replaceAll(RegExp(r'/+$'), '');
    final n = name.trim().replaceAll(RegExp(r'^/+'), '');
    if (d.isEmpty || d == '/') return n;
    return '${d.replaceFirst(RegExp(r'^/+'), '')}/$n';
  }

  static (String, String) _splitNasPath(String path) {
    final trimmed = path.trim().replaceFirst(RegExp(r'^/+'), '');
    if (trimmed.isEmpty) return ('/', '');
    final i = trimmed.lastIndexOf('/');
    if (i < 0) return ('/', trimmed);
    final dir = '/${trimmed.substring(0, i)}';
    return (dir == '/' ? '/' : dir, trimmed.substring(i + 1));
  }

  static (int, int)? _parseRange(String? header, int size) {
    if (size <= 0) return (0, 0);
    if (header == null || header.isEmpty) return (0, size - 1);
    final h = header.trim();
    final body = h.startsWith('bytes=') ? h.substring(6) : h;
    final parts = body.split('-');
    if (parts.length != 2) return null;
    if (parts[0].isEmpty) {
      final n = int.tryParse(parts[1]);
      if (n == null || n <= 0) return null;
      final start = size > n ? size - n : 0;
      return (start, size - 1);
    }
    final start = int.tryParse(parts[0]);
    if (start == null || start >= size) return null;
    final end = parts[1].isEmpty
        ? size - 1
        : (int.tryParse(parts[1]) ?? size - 1).clamp(0, size - 1);
    if (end < start) return null;
    return (start, end);
  }
}
