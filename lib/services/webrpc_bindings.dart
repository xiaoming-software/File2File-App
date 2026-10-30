import 'dart:ffi';
import 'dart:io';

import 'package:file2file/l10n/app_l10n.dart';
import 'package:ffi/ffi.dart';

typedef WebrpcNew = int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef WebrpcLoginStatus = int Function(int);
typedef WebrpcGetPort = int Function(int);
typedef WebrpcOpenSession = int Function(int, Pointer<Utf8>, Pointer<Utf8>);
typedef WebrpcCloseSession = int Function(int, int);
typedef WebrpcSessionSize = int Function(int);
typedef WebrpcTarToken = Pointer<Utf8> Function(int, int);
typedef WebrpcSendData = int Function(int, int, Pointer<Utf8>, int, int);
typedef WebrpcSendFile = int Function(int, int, Pointer<Utf8>);
typedef WebrpcSendFileDoneNative = Void Function(Int32);
typedef WebrpcSendFileAsyncNative = Int32 Function(
  UintPtr,
  Uint32,
  Pointer<Utf8>,
  Pointer<NativeFunction<WebrpcSendFileDoneNative>>,
);
typedef WebrpcSendFileAsyncDart = int Function(
  int,
  int,
  Pointer<Utf8>,
  Pointer<NativeFunction<WebrpcSendFileDoneNative>>,
);
typedef WebrpcFree = void Function(int);

/// Low-level C ABI bindings for webrpc mobile SDK.
class WebrpcBindings {
  WebrpcBindings._(
    DynamicLibrary lib,
    DynamicLibrary asyncLib, {
    required this.sendFileAsync,
  })  : newClient = lib.lookupFunction<
            UintPtr Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>),
            WebrpcNew>('WebrpcClient_New'),
        loginStatus = lib.lookupFunction<Int32 Function(UintPtr), WebrpcLoginStatus>(
          'WebrpcClient_LoginStatus',
        ),
        getReceivePort = lib.lookupFunction<Int32 Function(UintPtr), WebrpcGetPort>(
          'WebrpcClient_GetReceivePort',
        ),
        openSession = lib.lookupFunction<
            Uint32 Function(UintPtr, Pointer<Utf8>, Pointer<Utf8>),
            WebrpcOpenSession>('WebrpcClient_OpenSession'),
        closeSession = lib.lookupFunction<Int32 Function(UintPtr, Uint32), WebrpcCloseSession>(
          'WebrpcClient_CloseSession',
        ),
        sessionSize = lib.lookupFunction<Uint16 Function(UintPtr), WebrpcSessionSize>(
          'WebrpcClient_SessionSize',
        ),
        tarTokenBySession =
            lib.lookupFunction<Pointer<Utf8> Function(UintPtr, Uint32), WebrpcTarToken>(
          'WebrpcClient_TarTokenBySession',
        ),
        sendData = lib.lookupFunction<
            Int32 Function(UintPtr, Uint32, Pointer<Utf8>, Int32, Int64),
            WebrpcSendData>('WebrpcClient_SendData'),
        sendFile = lib.lookupFunction<Int32 Function(UintPtr, Uint32, Pointer<Utf8>), WebrpcSendFile>(
          'WebrpcClient_SendFile',
        ),
        freeClient = lib.lookupFunction<Void Function(UintPtr), WebrpcFree>('WebrpcClient_Free');

  final WebrpcNew newClient;
  final WebrpcLoginStatus loginStatus;
  final WebrpcGetPort getReceivePort;
  final WebrpcOpenSession openSession;
  final WebrpcCloseSession closeSession;
  final WebrpcSessionSize sessionSize;
  final WebrpcTarToken tarTokenBySession;
  final WebrpcSendData sendData;
  final WebrpcSendFile sendFile;
  /// Null on platforms without the pthread helper (e.g. bare macOS dylib).
  final WebrpcSendFileAsyncDart? sendFileAsync;
  final WebrpcFree freeClient;

  static WebrpcBindings? _instance;

  static WebrpcBindings load() {
    final existing = _instance;
    if (existing != null) return existing;

    late final DynamicLibrary lib;
    late final DynamicLibrary asyncLib;
    if (Platform.isAndroid) {
      lib = DynamicLibrary.open('libwebrpc.so');
      // pthread SendFile helper (built via android/app CMake). Optional:
      // missing/broken DT_NEEDED must not block login — service falls back to sync SendFile.
      DynamicLibrary? openedAsync;
      try {
        openedAsync = DynamicLibrary.open('libwebrpc_sendfile_async.so');
      } catch (_) {}
      asyncLib = openedAsync ?? lib;
    } else if (Platform.isIOS) {
      lib = DynamicLibrary.process();
      asyncLib = lib;
    } else if (Platform.isMacOS) {
      final candidates = [
        'libwebrpc-Mac.dylib',
        '${Directory.current.path}/webrpc-sdk/libwebrpc-Mac.dylib',
      ];
      DynamicLibrary? opened;
      for (final path in candidates) {
        try {
          opened = DynamicLibrary.open(path);
          break;
        } catch (_) {}
      }
      if (opened == null) {
        throw UnsupportedError(
          'macOS 调试需要 libwebrpc-Mac.dylib，或改用 Android/iOS 真机与 arm64 模拟器'.tr,
        );
      }
      lib = opened;
      // Desktop Mac helper is optional; fall back to sync SendFile path in service.
      asyncLib = lib;
    } else {
      throw UnsupportedError('当前平台暂不支持 webrpc SDK'.tr);
    }

    WebrpcSendFileAsyncDart? sendFileAsync;
    try {
      sendFileAsync =
          asyncLib.lookupFunction<WebrpcSendFileAsyncNative, WebrpcSendFileAsyncDart>(
        'WebrpcClient_SendFileAsync',
      );
    } catch (_) {
      sendFileAsync = null;
    }

    return _instance = WebrpcBindings._(lib, asyncLib, sendFileAsync: sendFileAsync);
  }
}
