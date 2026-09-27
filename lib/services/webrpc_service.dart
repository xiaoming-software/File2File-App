import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'webrpc_bindings.dart';

enum WebrpcLoginState { idle, connecting, online, failed }

class WebrpcDataEvent {
  WebrpcDataEvent({required this.sessionId, required this.bytes});
  final int sessionId;
  final Uint8List bytes;
}

/// One chunk of an incoming SendFile stream (files arrive in multiple chunks).
class WebrpcFileChunkEvent {
  WebrpcFileChunkEvent({
    required this.sessionId,
    required this.fileName,
    required this.bytes,
  });
  final int sessionId;
  final String fileName;
  final Uint8List bytes;
}

/// High-level webrpc client: login, callback TCP reader, sessions, send.
class WebrpcService {
  WebrpcBindings? _bindings;
  int _handle = 0;
  Socket? _callbackSocket;
  StreamSubscription<Uint8List>? _callbackSub;
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  final _dataController = StreamController<WebrpcDataEvent>.broadcast();
  final _fileController = StreamController<WebrpcFileChunkEvent>.broadcast();
  final _statusController = StreamController<WebrpcLoginState>.broadcast();

  WebrpcLoginState state = WebrpcLoginState.idle;
  String? lastError;
  int receivePort = 0;
  String currentToken = '';
  String currentPermission = '';

  Stream<WebrpcDataEvent> get onData => _dataController.stream;
  Stream<WebrpcFileChunkEvent> get onFileChunk => _fileController.stream;
  Stream<WebrpcLoginState> get onStatus => _statusController.stream;

  bool get isOnline => state == WebrpcLoginState.online && _handle != 0;

  Future<void> login({
    required String token,
    required String password,
    String permission = '',
  }) async {
    await logout();
    _setState(WebrpcLoginState.connecting);
    lastError = null;
    currentToken = token.trim();
    currentPermission = permission.trim();

    try {
      _bindings ??= WebrpcBindings.load();
      final b = _bindings!;

      final tokenPtr = currentToken.toNativeUtf8();
      final passPtr = password.toNativeUtf8();
      final permPtr = currentPermission.toNativeUtf8();
      try {
        _handle = b.newClient(tokenPtr, passPtr, permPtr);
      } finally {
        malloc.free(tokenPtr);
        malloc.free(passPtr);
        malloc.free(permPtr);
      }

      if (_handle == 0) {
        throw StateError('WebrpcClient_New 返回空句柄');
      }

      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        final status = b.loginStatus(_handle);
        if (status != 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      final status = b.loginStatus(_handle);
      if (status == 0) {
        throw TimeoutException('登录超时，请检查 Token / 网络');
      }

      receivePort = b.getReceivePort(_handle);
      if (receivePort <= 0) {
        throw StateError('回调端口无效: $receivePort');
      }

      await _startCallbackReader(receivePort);
      _setState(WebrpcLoginState.online);
    } catch (e, st) {
      debugPrint('webrpc login failed: $e\n$st');
      lastError = e.toString();
      await logout();
      _setState(WebrpcLoginState.failed);
      rethrow;
    }
  }

  Future<void> logout() async {
    await _stopCallbackReader();
    final handle = _handle;
    _handle = 0;
    receivePort = 0;
    currentToken = '';
    currentPermission = '';
    if (handle != 0) {
      try {
        _bindings?.freeClient(handle);
      } catch (e) {
        debugPrint('webrpc free failed: $e');
      }
    }
    if (state != WebrpcLoginState.failed) {
      _setState(WebrpcLoginState.idle);
    }
  }

  int openSession(String peerToken, {String permission = ''}) {
    _ensureOnline();
    final b = _bindings!;
    final toPtr = peerToken.toNativeUtf8();
    final permPtr = permission.toNativeUtf8();
    try {
      return b.openSession(_handle, toPtr, permPtr);
    } finally {
      malloc.free(toPtr);
      malloc.free(permPtr);
    }
  }

  int closeSession(int sessionId) {
    if (!isOnline || sessionId == 0) return 0;
    return _bindings!.closeSession(_handle, sessionId);
  }

  int sessionSize() {
    _ensureOnline();
    return _bindings!.sessionSize(_handle);
  }

  /// Desktop / Go samples: SendData returns **1** on success.
  bool sendRaw(int sessionId, List<int> data, {int timeoutMs = 10000}) {
    _ensureOnline();
    final ptr = malloc.allocate<Uint8>(data.length);
    try {
      ptr.asTypedList(data.length).setAll(0, data);
      final ret = _bindings!.sendData(
        _handle,
        sessionId,
        ptr.cast(),
        data.length,
        timeoutMs,
      );
      return ret == 1;
    } finally {
      malloc.free(ptr);
    }
  }

  bool sendJson(int sessionId, Map<String, dynamic> json, {int timeoutMs = 10000}) {
    return sendRaw(sessionId, utf8.encode(jsonEncode(json)), timeoutMs: timeoutMs);
  }

  /// SendFile returns **1** on success.
  bool sendFile(int sessionId, String filePath) {
    _ensureOnline();
    final pathPtr = filePath.toNativeUtf8();
    try {
      final ret = _bindings!.sendFile(_handle, sessionId, pathPtr);
      return ret == 1;
    } finally {
      malloc.free(pathPtr);
    }
  }

  void _ensureOnline() {
    if (!isOnline) {
      throw StateError('webrpc 未登录');
    }
  }

  void _setState(WebrpcLoginState next) {
    state = next;
    if (!_statusController.isClosed) {
      _statusController.add(next);
    }
  }

  Future<void> _startCallbackReader(int port) async {
    await _stopCallbackReader();
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 3),
    );
    _callbackSocket = socket;
    _buffer.clear();
    _callbackSub = socket.listen(
      _onCallbackBytes,
      onError: (Object e) {
        debugPrint('webrpc callback error: $e');
      },
      onDone: () {
        debugPrint('webrpc callback closed');
      },
      cancelOnError: false,
    );
  }

  Future<void> _stopCallbackReader() async {
    await _callbackSub?.cancel();
    _callbackSub = null;
    await _callbackSocket?.close();
    _callbackSocket = null;
    _buffer.clear();
  }

  void _onCallbackBytes(Uint8List chunk) {
    _buffer.add(chunk);
    var data = _buffer.takeBytes();
    var offset = 0;

    while (true) {
      if (data.length - offset < 5) break;
      final sessionId = _readU32be(data, offset);
      final type = data[offset + 4];

      if (type == 2) {
        if (data.length - offset < 9) break;
        final len = _readU32be(data, offset + 5);
        if (data.length - offset < 9 + len) break;
        final payload = Uint8List.sublistView(data, offset + 9, offset + 9 + len);
        _dataController.add(
          WebrpcDataEvent(sessionId: sessionId, bytes: Uint8List.fromList(payload)),
        );
        offset += 9 + len;
      } else if (type == 1) {
        if (data.length - offset < 9) break;
        final nameLen = _readU32be(data, offset + 5);
        if (nameLen > 4096) {
          offset += 1;
          continue;
        }
        if (data.length - offset < 9 + nameLen + 4) break;
        final nameStart = offset + 9;
        final nameBytes = Uint8List.sublistView(data, nameStart, nameStart + nameLen);
        final dataLen = _readU32be(data, nameStart + nameLen);
        if (data.length - offset < 9 + nameLen + 4 + dataLen) break;
        final fileStart = nameStart + nameLen + 4;
        final fileBytes =
            Uint8List.sublistView(data, fileStart, fileStart + dataLen);
        final name = utf8.decode(nameBytes, allowMalformed: true);
        _fileController.add(
          WebrpcFileChunkEvent(
            sessionId: sessionId,
            fileName: name,
            bytes: Uint8List.fromList(fileBytes),
          ),
        );
        offset += 9 + nameLen + 4 + dataLen;
      } else {
        offset += 1;
      }
    }

    if (offset < data.length) {
      _buffer.add(Uint8List.sublistView(data, offset));
    }
  }

  int _readU32be(Uint8List data, int offset) {
    return (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
  }

  Future<void> dispose() async {
    await logout();
    await _dataController.close();
    await _fileController.close();
    await _statusController.close();
  }
}
