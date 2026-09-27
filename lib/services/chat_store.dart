import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/chat_models.dart';

class ChatStore {
  Future<Directory> _root() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'file2file_data'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _sessionsFile(String owner) async {
    final root = await _root();
    final dir = Directory(p.join(root.path, 'sessions'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, '${_safe(owner)}.json'));
  }

  Future<File> _chatsFile(String owner, String peer) async {
    final root = await _root();
    final dir = Directory(p.join(root.path, 'chats', _safe(owner)));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, '${_safe(peer)}.json'));
  }

  Future<Directory> incomingDir(String owner, String peer) async {
    final root = await _root();
    final dir = Directory(p.join(root.path, 'files', _safe(owner), _safe(peer)));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> incomingPath(String owner, String peer, String fileName) async {
    final dir = await incomingDir(owner, peer);
    return p.join(dir.path, safeFileName(fileName));
  }

  Future<List<ChatSession>> loadSessions(String owner) async {
    final file = await _sessionsFile(owner);
    if (!await file.exists()) return [];
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return [];
      return raw
          .whereType<Map>()
          .map((e) => ChatSession.fromMetaJson(Map<String, dynamic>.from(e)))
          .where((s) => s.peerToken.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveSessions(String owner, List<ChatSession> sessions) async {
    final file = await _sessionsFile(owner);
    final list = sessions.map((s) => s.toMetaJson()).toList();
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(list));
  }

  Future<List<ChatMessage>> loadMessages(String owner, String peer) async {
    final file = await _chatsFile(owner, peer);
    if (!await file.exists()) return [];
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return [];
      return raw
          .whereType<Map>()
          .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveMessages(
    String owner,
    String peer,
    List<ChatMessage> messages,
  ) async {
    final file = await _chatsFile(owner, peer);
    final list = messages.map((m) => m.toJson()).toList();
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(list));
  }

  Future<void> clearMessages(String owner, String peer) async {
    final file = await _chatsFile(owner, peer);
    if (await file.exists()) await file.delete();
    final dir = await incomingDir(owner, peer);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  Future<void> deleteSessionData(String owner, String peer) async {
    await clearMessages(owner, peer);
  }

  String _safe(String s) =>
      s.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}
