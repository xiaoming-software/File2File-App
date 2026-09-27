import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/drive_models.dart';
import '../services/drive_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/nas_file_icon.dart';

/// Pick a target folder under the same drive session for move.
class DriveMoveScreen extends StatefulWidget {
  const DriveMoveScreen({
    super.key,
    required this.sessionId,
    required this.names,
  });

  final String sessionId;
  final List<String> names;

  @override
  State<DriveMoveScreen> createState() => _DriveMoveScreenState();
}

class _DriveMoveScreenState extends State<DriveMoveScreen> {
  late String _fromPath;
  String _browsePath = '/';
  List<NasEntry> _dirs = [];
  bool _listing = false;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _fromPath = '/';
    _browsePath = '/';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final drive = context.read<DriveController>();
      final session = drive.sessionById(widget.sessionId);
      setState(() {
        _fromPath = session?.currentPath ?? '/';
        _browsePath = _fromPath;
      });
      _load(_browsePath);
    });
  }

  Future<void> _load(String path) async {
    final drive = context.read<DriveController>();
    final session = drive.sessionById(widget.sessionId);
    if (session == null) return;
    setState(() {
      _listing = true;
      _error = '';
      _browsePath = normalizeNasPath(path);
    });
    // Temporarily list via protocol without permanently changing UX path:
    // we use listPath then snapshot dirs, then restore fromPath.
    final restore = _fromPath;
    try {
      await drive.listPath(session, _browsePath);
      if (!mounted) return;
      setState(() {
        _dirs = session.entries.where((e) => e.isDir).toList();
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      try {
        await drive.listPath(session, restore);
      } catch (_) {}
      if (mounted) setState(() => _listing = false);
    }
  }

  Future<void> _confirm(DriveSession session) async {
    setState(() => _busy = true);
    try {
      await context.read<DriveController>().moveNames(
            session,
            names: widget.names,
            fromPath: _fromPath,
            targetPath: _browsePath,
          );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final drive = context.watch<DriveController>();
    final session = drive.sessionById(widget.sessionId);
    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('移动到')),
        body: const Center(child: Text('会话不存在')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('移动到'),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => _confirm(session),
            child: const Text('移到此处'),
          ),
        ],
      ),
      body: Column(
        children: [
          Material(
            color: const Color(0xFFF3F6F8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _browsePath == '/' || _busy || _listing
                        ? null
                        : () => _load(parentNasPath(_browsePath)),
                    icon: const Icon(Icons.arrow_upward),
                  ),
                  Expanded(
                    child: Text(
                      _browsePath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (_listing)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              '将 ${widget.names.length} 项从 $_fromPath 移动到上方目录',
              style: TextStyle(color: AppTheme.ink.withValues(alpha: 0.55)),
            ),
          ),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(_error, style: TextStyle(color: Colors.red.shade700)),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _dirs.length,
              itemBuilder: (context, index) {
                final e = _dirs[index];
                return ListTile(
                  leading: NasFileIcon.forName(e.name, isDir: true),
                  title: Text(e.name),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy || _listing
                      ? null
                      : () => _load(joinNasPath(_browsePath, e.name)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
