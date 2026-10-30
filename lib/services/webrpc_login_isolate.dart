import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'webrpc_bindings.dart';

/// Serializable outcome of blocking webrpc Login (safe to pass across isolates).
class WebrpcLoginNativeOutcome {
  const WebrpcLoginNativeOutcome._({
    required this.handle,
    required this.receivePort,
    this.errorCode,
  });

  const WebrpcLoginNativeOutcome.ok({
    required int handle,
    required int receivePort,
  }) : this._(handle: handle, receivePort: receivePort);

  const WebrpcLoginNativeOutcome.fail(String errorCode)
      : this._(handle: 0, receivePort: 0, errorCode: errorCode);

  final int handle;
  final int receivePort;

  /// Stable codes for main-isolate localization:
  /// `empty-handle` | `timeout` | `bad-port` | `load-failed` | `error:<msg>`
  final String? errorCode;

  bool get ok => errorCode == null && handle != 0 && receivePort > 0;
}

/// Runs [WebrpcClient_New] + LoginStatus poll off the UI isolate.
///
/// The returned client handle is a native pointer-sized int; the main isolate
/// loads its own [WebrpcBindings] view of the same .so and uses that handle.
Future<WebrpcLoginNativeOutcome> webrpcLoginInBackground({
  required String token,
  required String password,
  required String permission,
  Duration timeout = const Duration(seconds: 15),
}) {
  return Isolate.run(
    () => webrpcLoginBlocking(
      token: token,
      password: password,
      permission: permission,
      timeout: timeout,
    ),
  );
}

/// Sync login body — call only from a background isolate (or tests).
WebrpcLoginNativeOutcome webrpcLoginBlocking({
  required String token,
  required String password,
  required String permission,
  Duration timeout = const Duration(seconds: 15),
}) {
  final WebrpcBindings b;
  try {
    b = WebrpcBindings.load();
  } catch (e) {
    return WebrpcLoginNativeOutcome.fail('load-failed:$e');
  }

  final tokenPtr = token.toNativeUtf8();
  final passPtr = password.toNativeUtf8();
  final permPtr = permission.toNativeUtf8();
  late final int handle;
  try {
    handle = b.newClient(tokenPtr, passPtr, permPtr);
  } catch (e) {
    return WebrpcLoginNativeOutcome.fail('error:$e');
  } finally {
    malloc.free(tokenPtr);
    malloc.free(passPtr);
    malloc.free(permPtr);
  }

  if (handle == 0) {
    return const WebrpcLoginNativeOutcome.fail('empty-handle');
  }

  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    try {
      if (b.loginStatus(handle) != 0) break;
    } catch (e) {
      _safeFree(b, handle);
      return WebrpcLoginNativeOutcome.fail('error:$e');
    }
    // Block this isolate only — UI isolate stays free.
    sleep(const Duration(milliseconds: 200));
  }

  final status = b.loginStatus(handle);
  if (status == 0) {
    _safeFree(b, handle);
    return const WebrpcLoginNativeOutcome.fail('timeout');
  }

  final port = b.getReceivePort(handle);
  if (port <= 0) {
    _safeFree(b, handle);
    return const WebrpcLoginNativeOutcome.fail('bad-port');
  }

  return WebrpcLoginNativeOutcome.ok(handle: handle, receivePort: port);
}

void _safeFree(WebrpcBindings b, int handle) {
  if (handle == 0) return;
  try {
    b.freeClient(handle);
  } catch (_) {}
}
