import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Release-safe ring log written under Documents/file2file-debug.log
/// so we can pull it from the device when `flutter run --release` shows nothing.
class AppDebugLog {
  AppDebugLog._();

  static IOSink? _sink;
  static Future<void>? _init;
  static String? path;

  static Future<void> ensure() {
    return _init ??= () async {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/file2file-debug.log');
        path = file.path;
        _sink = file.openWrite(mode: FileMode.append);
        log('---- log open ${DateTime.now().toIso8601String()} ----');
      } catch (e) {
        debugPrint('AppDebugLog init failed: $e');
      }
    }();
  }

  static void log(String msg) {
    final line = '${DateTime.now().toIso8601String()} $msg';
    // ignore: avoid_print
    print(line);
    debugPrint(line);
    unawaited(ensure().then((_) {
      try {
        _sink?.writeln(line);
      } catch (_) {}
    }));
  }
}
