import 'dart:ffi';
import 'dart:io';

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
typedef WebrpcFree = void Function(int);

/// Low-level C ABI bindings for webrpc mobile SDK.
class WebrpcBindings {
  WebrpcBindings._(DynamicLibrary lib)
      : newClient = lib.lookupFunction<
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
  final WebrpcFree freeClient;

  static WebrpcBindings? _instance;

  static WebrpcBindings load() {
    final existing = _instance;
    if (existing != null) return existing;

    final DynamicLibrary lib;
    if (Platform.isAndroid) {
      lib = DynamicLibrary.open('libwebrpc.so');
    } else if (Platform.isIOS) {
      lib = DynamicLibrary.process();
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
          'macOS 调试需要 libwebrpc-Mac.dylib，或改用 Android/iOS 真机与 arm64 模拟器',
        );
      }
      lib = opened;
    } else {
      throw UnsupportedError('当前平台暂不支持 webrpc SDK');
    }

    return _instance = WebrpcBindings._(lib);
  }
}
