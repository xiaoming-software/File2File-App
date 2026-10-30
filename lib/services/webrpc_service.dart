import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:file2file/l10n/app_l10n.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'app_debug_log.dart';
import 'webrpc_bindings.dart';
import 'webrpc_ffi_isolate.dart';
import 'webrpc_login_isolate.dart';

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
///
/// Inbound peer traffic is **not** delivered through FFI callbacks. The native
/// SDK exposes a localhost TCP port (`GetReceivePort`); Dart must keep a socket
/// connected and parse frames. Send uses FFI directly — so “can send, cannot
/// receive” almost always means this callback socket died or never stayed up.
class WebrpcService {
  WebrpcBindings? _bindings;
  int _handle = 0;
  Socket? _callbackSocket;
  StreamSubscription<Uint8List>? _callbackSub;
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  int _callbackEpoch = 0;
  bool _callbackReconnectScheduled = false;
  Timer? _callbackHealthTimer;
  DateTime? _lastCallbackBytesAt;
  bool _ensureCallbackInFlight = false;

  final _dataController = StreamController<WebrpcDataEvent>.broadcast();
  final _fileController = StreamController<WebrpcFileChunkEvent>.broadcast();
  final _statusController = StreamController<WebrpcLoginState>.broadcast();

  WebrpcLoginState state = WebrpcLoginState.idle;
  String? lastError;
  int receivePort = 0;
  String currentToken = '';
  String currentPermission = '';
  /// Last callback-socket status (visible in release; debugPrint is often silent).
  String callbackStatus = 'idle';

  Stream<WebrpcDataEvent> get onData => _dataController.stream;
  Stream<WebrpcFileChunkEvent> get onFileChunk => _fileController.stream;
  Stream<WebrpcLoginState> get onStatus => _statusController.stream;

  bool get isOnline => state == WebrpcLoginState.online && _handle != 0;

  /// Native gomobile login flag — UI may still say online after iOS suspend.
  bool get nativeLoginAlive {
    if (_handle == 0 || _bindings == null) return false;
    try {
      return _bindings!.loginStatus(_handle) != 0;
    } catch (_) {
      return false;
    }
  }

  /// Dart state drifted offline while native LoginStatus is still 1 — restore
  /// without calling logout/login (which would drop a healthy session).
  void resyncOnlineFromNative() {
    if (_handle == 0 || _bindings == null || !nativeLoginAlive) return;
    try {
      if (receivePort <= 0) {
        receivePort = _bindings!.getReceivePort(_handle);
      }
    } catch (_) {}
    if (receivePort <= 0) return;
    if (state != WebrpcLoginState.online) {
      _setState(WebrpcLoginState.online);
    }
    _startCallbackHealthTimer();
  }

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
      // Main-isolate bindings for post-login FFI; NewClient runs off-UI.
      _bindings ??= WebrpcBindings.load();

      // Let recovering banner / connecting UI paint before isolate work.
      await Future<void>.delayed(Duration.zero);

      final outcome = await webrpcLoginInBackground(
        token: currentToken,
        password: password.trim(),
        permission: currentPermission,
      );
      if (!outcome.ok) {
        throw _loginOutcomeError(outcome);
      }

      _handle = outcome.handle;
      receivePort = outcome.receivePort;

      // Confirm native still alive via this isolate's binding view.
      if (!nativeLoginAlive) {
        throw TimeoutException('登录超时，请检查 Token / 网络'.tr);
      }

      await _startCallbackReader(receivePort);
      if (_callbackSocket == null) {
        throw StateError('回调读取未建立'.tr);
      }
      _setState(WebrpcLoginState.online);
      _startCallbackHealthTimer();
    } catch (e, st) {
      debugPrint('webrpc login failed: $e\n$st');
      lastError = e.toString();
      await logout();
      _setState(WebrpcLoginState.failed);
      rethrow;
    }
  }

  Object _loginOutcomeError(WebrpcLoginNativeOutcome outcome) {
    final code = outcome.errorCode ?? '';
    if (code == 'empty-handle') {
      return StateError('WebrpcClient_New 返回空句柄'.tr);
    }
    if (code == 'timeout') {
      return TimeoutException('登录超时，请检查 Token / 网络'.tr);
    }
    if (code == 'bad-port') {
      return StateError('回调端口无效'.tr);
    }
    if (code.startsWith('load-failed')) {
      return StateError('webrpc 库加载失败'.tr);
    }
    final detail = code.startsWith('error:') ? code.substring(6) : code;
    if (detail.isEmpty) {
      return StateError('登录失败'.tr);
    }
    return StateError(detail);
  }

  /// Repair callback only when missing/dead.
  /// Never tear down a healthy socket — that drops in-flight chat/NAS frames.
  Future<void> ensureCallbackAlive({bool force = false}) async {
    if (!isOnline || receivePort <= 0) return;
    if (_ensureCallbackInFlight) return;
    if (_callbackSocket != null) {
      try {
        // ignore: unnecessary_statements
        _callbackSocket!.remotePort;
        // Connected and usable — do not rebind even if caller passed force.
        return;
      } catch (_) {
        _logCallback('socket dead, repairing');
      }
    }
    _ensureCallbackInFlight = true;
    try {
      _logCallback('ensure alive (repair)');
      await _startCallbackReader(receivePort);
    } catch (e) {
      _logCallback('ensure alive failed: $e');
    } finally {
      _ensureCallbackInFlight = false;
    }
  }

  /// True when the localhost callback TCP client is connected.
  bool get isCallbackConnected {
    final s = _callbackSocket;
    if (s == null) return false;
    try {
      // ignore: unnecessary_statements
      s.remotePort;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Hard rebind — used when inbound traffic is missing (Go may have niled
  /// receiveConn and queued frames; Accept+flush needs a new TCP client).
  /// Returns false when the Go listener is gone (typical after iOS suspend).
  Future<bool> rebindCallback() async {
    if (_handle == 0 || receivePort <= 0) return false;
    if (_ensureCallbackInFlight) {
      final deadline = DateTime.now().add(const Duration(seconds: 6));
      while (_ensureCallbackInFlight && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      return isCallbackConnected;
    }
    _ensureCallbackInFlight = true;
    try {
      _logCallback('rebind callback');
      await _startCallbackReader(receivePort);
      final ok = isCallbackConnected;
      if (!ok) {
        _logCallback('rebind produced no live socket');
      }
      return ok;
    } catch (e) {
      _logCallback('rebind failed: $e');
      return false;
    } finally {
      _ensureCallbackInFlight = false;
    }
  }

  /// Probe after resume: live socket OK, else rebind; false ⇒ need full Login.
  Future<bool> probeCallbackHealthy() async {
    if (_handle == 0 || receivePort <= 0) return false;
    if (isCallbackConnected) return true;
    return rebindCallback();
  }

  void _startCallbackHealthTimer() {
    _callbackHealthTimer?.cancel();
    // Only repair a missing/dead socket. Do NOT periodically force-rebind:
    // tearing down a healthy callback drops in-flight chat/NAS frames (flaky
    // receive + empty drive lists).
    _callbackHealthTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!isOnline || receivePort <= 0) return;
      if (_callbackSocket == null) {
        unawaited(ensureCallbackAlive(force: true));
        return;
      }
      try {
        // ignore: unnecessary_statements
        _callbackSocket!.remotePort;
      } catch (e) {
        _logCallback('socket dead: $e');
        unawaited(ensureCallbackAlive(force: true));
      }
    });
  }

  void _stopCallbackHealthTimer() {
    _callbackHealthTimer?.cancel();
    _callbackHealthTimer = null;
  }

  Future<void> logout() async {
    _stopCallbackHealthTimer();
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

  /// Non-blocking OpenSession (peer offline can stall native for seconds).
  Future<int> openSessionAsync(String peerToken, {String permission = ''}) async {
    _ensureOnline();
    // Paint connecting UI before isolate work.
    await Future<void>.delayed(Duration.zero);
    return webrpcOpenSessionInBackground(
      clientHandle: _handle,
      peerToken: peerToken.trim(),
      permission: permission.trim(),
    );
  }

  int closeSession(int sessionId) {
    if (!isOnline || sessionId == 0) return 0;
    return _bindings!.closeSession(_handle, sessionId);
  }

  /// Peer token for an active webrpc session (caller must free is handled here).
  String peerTokenOf(int sessionId) {
    if (!isOnline || sessionId == 0) return '';
    final ptr = _bindings!.tarTokenBySession(_handle, sessionId);
    if (ptr == nullptr) return '';
    try {
      return ptr.toDartString().trim();
    } finally {
      malloc.free(ptr);
    }
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

  /// Non-blocking SendData — use for hello / long timeoutMs paths.
  Future<bool> sendRawAsync(
    int sessionId,
    List<int> data, {
    int timeoutMs = 10000,
  }) async {
    _ensureOnline();
    await Future<void>.delayed(Duration.zero);
    return webrpcSendDataInBackground(
      clientHandle: _handle,
      sessionId: sessionId,
      bytes: Uint8List.fromList(data),
      timeoutMs: timeoutMs,
    );
  }

  Future<bool> sendJsonAsync(
    int sessionId,
    Map<String, dynamic> json, {
    int timeoutMs = 10000,
  }) {
    return sendRawAsync(
      sessionId,
      utf8.encode(jsonEncode(json)),
      timeoutMs: timeoutMs,
    );
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

  /// SendFile on a native pthread (not Dart isolate / not UI isolate).
  /// Matches Desktop: UI stays responsive; type=3/4 + backPut update progress.
  Future<bool> sendFileAsync(int sessionId, String filePath) async {
    _ensureOnline();
    final b = _bindings!;
    final asyncFn = b.sendFileAsync;
    if (asyncFn == null) {
      // macOS debug fallback — sync (may block UI briefly).
      await Future<void>.delayed(Duration.zero);
      return sendFile(sessionId, filePath);
    }

    final completer = Completer<bool>();
    late final NativeCallable<WebrpcSendFileDoneNative> callable;
    var closed = false;
    void closeCallable() {
      if (closed) return;
      closed = true;
      callable.close();
    }

    callable = NativeCallable<WebrpcSendFileDoneNative>.listener((int result) {
      if (!completer.isCompleted) {
        completer.complete(result == 1);
      }
      scheduleMicrotask(closeCallable);
    });

    final pathPtr = filePath.toNativeUtf8();
    try {
      final started = asyncFn(
        _handle,
        sessionId,
        pathPtr,
        callable.nativeFunction,
      );
      if (started == 0) {
        closeCallable();
        return false;
      }
      return await completer.future;
    } catch (e) {
      closeCallable();
      rethrow;
    } finally {
      malloc.free(pathPtr);
    }
  }

  void _ensureOnline() {
    if (!isOnline) {
      throw StateError('webrpc 未登录'.tr);
    }
  }

  void _setState(WebrpcLoginState next) {
    state = next;
    if (!_statusController.isClosed) {
      _statusController.add(next);
    }
  }

  void _logCallback(String msg) {
    callbackStatus = msg;
    AppDebugLog.log('webrpc callback: $msg');
  }

  Future<void> _startCallbackReader(int port) async {
    final epoch = ++_callbackEpoch;
    await _stopCallbackReader(bumpEpoch: false);
    _buffer.clear();

    Socket? socket;
    Object? lastErr;
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (epoch != _callbackEpoch) return;
      try {
        // Prefer literal IPv4 — matches desktop/Go listener and avoids ::1 mismatch.
        socket = await Socket.connect(
          InternetAddress('127.0.0.1'),
          port,
          timeout: const Duration(seconds: 2),
        );
        break;
      } catch (e) {
        lastErr = e;
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
    if (socket == null) {
      _logCallback('connect failed 127.0.0.1:$port err=$lastErr');
      throw StateError(AppL10n.current.fill(
        r'回调端口连接失败: $receivePort',
        {r'$receivePort': '$port'},
      ));
    }
    if (epoch != _callbackEpoch) {
      await socket.close();
      return;
    }

    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}

    _callbackSocket = socket;
    _lastCallbackBytesAt = DateTime.now();
    _logCallback('connected 127.0.0.1:$port');
    _callbackSub = socket.listen(
      (chunk) {
        _lastCallbackBytesAt = DateTime.now();
        AppDebugLog.log('rx chunk bytes=${chunk.length}');
        try {
          _onCallbackBytes(chunk);
        } catch (e, st) {
          AppDebugLog.log('rx parse error: $e\n$st');
        }
      },
      onError: (Object e) {
        _logCallback('error: $e');
        _scheduleCallbackReconnect(port, epoch);
      },
      onDone: () {
        _logCallback('closed by peer');
        _scheduleCallbackReconnect(port, epoch);
      },
      cancelOnError: false,
    );
  }

  void _scheduleCallbackReconnect(int port, int epoch) {
    if (epoch != _callbackEpoch) return;
    if (!isOnline || receivePort != port) return;
    if (_callbackReconnectScheduled) return;
    _callbackReconnectScheduled = true;
    // Delay slightly so iOS can finish debugger/USB teardown before rebind.
    Future<void>.delayed(const Duration(milliseconds: 400), () async {
      _callbackReconnectScheduled = false;
      if (epoch != _callbackEpoch) return;
      if (!isOnline || receivePort != port) return;
      _logCallback('reconnecting 127.0.0.1:$port');
      try {
        await _startCallbackReader(port);
      } catch (e) {
        _logCallback('reconnect failed: $e');
        // Retry again shortly — common after flutter run USB detach.
        Future<void>.delayed(const Duration(seconds: 2), () {
          if (isOnline && receivePort == port) {
            unawaited(ensureCallbackAlive(force: true));
          }
        });
      }
    });
  }

  Future<void> _stopCallbackReader({bool bumpEpoch = true}) async {
    if (bumpEpoch) {
      _callbackEpoch++;
    }
    final sub = _callbackSub;
    final sock = _callbackSocket;
    _callbackSub = null;
    _callbackSocket = null;
    await sub?.cancel();
    try {
      await sock?.close();
    } catch (_) {}
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
        final preview = utf8.decode(
          payload.length > 96 ? payload.sublist(0, 96) : payload,
          allowMalformed: true,
        );
        AppDebugLog.log('rx data session=$sessionId len=$len preview=$preview');
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
