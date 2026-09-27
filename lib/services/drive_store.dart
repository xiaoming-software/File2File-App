import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/drive_models.dart';

class DriveStore {
  Future<Directory> _root() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'file2file_data', 'drives'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _listFile(String owner) async {
    final root = await _root();
    return File(p.join(root.path, '${_safe(owner)}.json'));
  }

  Future<Directory> downloadDir(String owner, String peer) async {
    final root = await _root();
    final dir = Directory(p.join(root.path, 'files', _safe(owner), _safe(peer)));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> downloadPath(String owner, String peer, String fileName) async {
    final dir = await downloadDir(owner, peer);
    return p.join(dir.path, safeFileName(fileName));
  }

  Future<List<DriveSession>> load(String owner) async {
    final file = await _listFile(owner);
    if (!await file.exists()) return [];
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return [];
      return raw
          .whereType<Map>()
          .map((e) => DriveSession.fromMetaJson(Map<String, dynamic>.from(e)))
          .where((s) => s.peerToken.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> save(String owner, List<DriveSession> sessions) async {
    final file = await _listFile(owner);
    await file.writeAsString(encodeDriveList(sessions));
  }

  Future<void> deleteDriveData(String owner, String peer) async {
    final root = await _root();
    final dir = Directory(p.join(root.path, 'files', _safe(owner), _safe(peer)));
    if (await dir.exists()) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  String _safe(String raw) {
    final s = raw.trim().replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    if (s.isEmpty) return 'unknown';
    return s.length > 80 ? s.substring(0, 80) : s;
  }
}
