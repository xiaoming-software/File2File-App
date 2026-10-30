import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'webrpc_bindings.dart';

/// Off-UI [WebrpcClient_OpenSession] — peer offline can block for seconds.
Future<int> webrpcOpenSessionInBackground({
  required int clientHandle,
  required String peerToken,
  required String permission,
}) {
  if (clientHandle == 0) return Future.value(0);
  return Isolate.run(
    () => webrpcOpenSessionBlocking(
      clientHandle: clientHandle,
      peerToken: peerToken,
      permission: permission,
    ),
  );
}

int webrpcOpenSessionBlocking({
  required int clientHandle,
  required String peerToken,
  required String permission,
}) {
  final b = WebrpcBindings.load();
  final toPtr = peerToken.toNativeUtf8();
  final permPtr = permission.toNativeUtf8();
  try {
    return b.openSession(clientHandle, toPtr, permPtr);
  } finally {
    malloc.free(toPtr);
    malloc.free(permPtr);
  }
}

/// Off-UI [WebrpcClient_SendData] — long timeoutMs must not freeze the UI isolate.
Future<bool> webrpcSendDataInBackground({
  required int clientHandle,
  required int sessionId,
  required Uint8List bytes,
  required int timeoutMs,
}) {
  if (clientHandle == 0 || sessionId == 0) return Future.value(false);
  // Copy so the isolate owns the payload.
  final copy = Uint8List.fromList(bytes);
  return Isolate.run(
    () => webrpcSendDataBlocking(
      clientHandle: clientHandle,
      sessionId: sessionId,
      bytes: copy,
      timeoutMs: timeoutMs,
    ),
  );
}

bool webrpcSendDataBlocking({
  required int clientHandle,
  required int sessionId,
  required Uint8List bytes,
  required int timeoutMs,
}) {
  final b = WebrpcBindings.load();
  final ptr = malloc.allocate<Uint8>(bytes.length);
  try {
    ptr.asTypedList(bytes.length).setAll(0, bytes);
    final ret = b.sendData(
      clientHandle,
      sessionId,
      ptr.cast(),
      bytes.length,
      timeoutMs,
    );
    return ret == 1;
  } finally {
    malloc.free(ptr);
  }
}
