import 'dart:io';

import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/chat_models.dart';

class MediaSaveService {
  Future<String> savePathToAlbum(String path, {required bool video}) async {
    if (path.isEmpty || !await File(path).exists()) {
      throw StateError('本地文件不存在');
    }
    final hasAccess = await Gal.hasAccess(toAlbum: true);
    if (!hasAccess) {
      final ok = await Gal.requestAccess(toAlbum: true);
      if (!ok) throw StateError('没有相册写入权限');
    }
    if (video) {
      await Gal.putVideo(path, album: 'File2File');
    } else {
      await Gal.putImage(path, album: 'File2File');
    }
    return '已保存到相册';
  }

  Future<String> saveToAlbum(ChatMessage msg) async {
    final srcPath = await _requireLocal(msg);
    if (msg.kind != ChatMsgKind.image && msg.kind != ChatMsgKind.video) {
      throw StateError('仅图片/视频可保存到相册');
    }
    return savePathToAlbum(srcPath, video: msg.kind == ChatMsgKind.video);
  }

  Future<String> saveToDownloads(ChatMessage msg) async {
    final srcPath = await _requireLocal(msg);
    final name = safeFileName(
      msg.title.isNotEmpty ? msg.title : p.basename(srcPath),
    );

    if (Platform.isAndroid) {
      final status = await Permission.manageExternalStorage.request();
      if (!status.isGranted) {
        final storage = await Permission.storage.request();
        if (!storage.isGranted) {
          throw StateError('没有存储权限');
        }
      }
    }

    Directory? downloads;
    if (Platform.isAndroid) {
      downloads = Directory('/storage/emulated/0/Download');
      if (!await downloads.exists()) {
        downloads = await getExternalStorageDirectory();
      }
    } else {
      downloads = await getApplicationDocumentsDirectory();
    }
    if (downloads == null) throw StateError('无法定位下载目录');
    if (!await downloads.exists()) await downloads.create(recursive: true);

    var dest = File(p.join(downloads.path, name));
    if (await dest.exists()) {
      final stem = p.basenameWithoutExtension(name);
      final ext = p.extension(name);
      dest = File(
        p.join(
          downloads.path,
          '$stem-${DateTime.now().millisecondsSinceEpoch}$ext',
        ),
      );
    }
    await File(srcPath).copy(dest.path);
    return '已保存到 ${dest.path}';
  }

  /// Legacy helper: media → album, others → downloads.
  Future<String> saveMessage(ChatMessage msg) async {
    if (msg.kind == ChatMsgKind.image || msg.kind == ChatMsgKind.video) {
      return saveToAlbum(msg);
    }
    return saveToDownloads(msg);
  }

  Future<String> _requireLocal(ChatMessage msg) async {
    final srcPath = msg.filePath;
    if (srcPath.isEmpty || !await File(srcPath).exists()) {
      throw StateError('本地文件不存在');
    }
    return srcPath;
  }
}
