import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/drive_models.dart';
import '../models/nas_file_kind.dart';
import '../services/drive_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/nas_file_icon.dart';
import '../widgets/nas_storage_header.dart';
import 'drive_move_screen.dart';
import 'drive_preview_screen.dart';
import 'drive_tasks_screen.dart';

class DriveBrowserScreen extends StatefulWidget {
  const DriveBrowserScreen({super.key, required this.sessionId});
  final String sessionId;

  @override
  State<DriveBrowserScreen> createState() => _DriveBrowserScreenState();
}

class _DriveBrowserScreenState extends State<DriveBrowserScreen> {
  bool _busy = false;
  bool _selectMode = false;
  final Set<String> _selected = {};
  final _searchCtrl = TextEditingController();
  final _picker = ImagePicker();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  DriveSession? _session(DriveController drive) =>
      drive.sessionById(widget.sessionId);

  Future<void> _ensureConnected(DriveSession session) async {
    if (session.connected) return;
    await context.read<DriveController>().connect(session);
  }

  void _toggleSelect(String name) {
    setState(() {
      if (_selected.contains(name)) {
        _selected.remove(name);
      } else {
        _selected.add(name);
      }
      if (_selected.isEmpty) _selectMode = false;
    });
  }

  Future<void> _openEntry(DriveSession session, NasEntry entry) async {
    final drive = context.read<DriveController>();
    if (entry.isDir) {
      try {
        await drive.listPath(
          session,
          joinNasPath(session.currentPath, entry.name),
        );
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
        }
      }
      return;
    }
    if (entry.previewKind != DrivePreviewKind.none) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DrivePreviewScreen(
            sessionId: session.id,
            entry: entry,
            remoteDir: session.currentPath,
          ),
        ),
      );
      return;
    }
    // Non-previewable: offer download via sheet
    await _showItemActions(session, entry);
  }

  Future<void> _showItemActions(DriveSession session, NasEntry entry) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(entry.name),
              subtitle: Text(entry.isDir ? '文件夹' : formatBytes(entry.size)),
            ),
            if (!entry.isDir)
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('下载'),
                onTap: () => Navigator.pop(ctx, 'download'),
              ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('移动'),
              onTap: () => Navigator.pop(ctx, 'move'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Colors.red.shade700),
              title: Text('删除', style: TextStyle(color: Colors.red.shade700)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    await _runAction(session, [entry.name], action, entry: entry);
  }

  Future<void> _runAction(
    DriveSession session,
    List<String> names,
    String action, {
    NasEntry? entry,
  }) async {
    final drive = context.read<DriveController>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await _ensureConnected(session);
      if (!mounted) return;
      switch (action) {
        case 'download':
          final entries = names
              .map((n) {
                for (final e in session.entries) {
                  if (e.name == n) return e;
                }
                return NasEntry(name: n, isDir: false, size: entry?.size ?? 0);
              })
              .where((e) => !e.isDir)
              .toList();
          drive.enqueueDownloads(session, entries);
          messenger.showSnackBar(
            SnackBar(content: Text('已加入下载队列（${entries.length}）')),
          );
        case 'rename':
          if (names.length != 1) return;
          final next = await _promptName('重命名', names.first);
          if (next == null || next.trim().isEmpty || !mounted) return;
          await drive.rename(session, name: names.first, newName: next.trim());
        case 'delete':
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              content: Text('删除 ${names.length} 项？不可恢复。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('删除'),
                ),
              ],
            ),
          );
          if (ok == true && mounted) {
            await drive.deleteNames(session, names);
          }
        case 'move':
          if (!mounted) return;
          final moved = await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => DriveMoveScreen(
                sessionId: session.id,
                names: names,
              ),
            ),
          );
          if (moved == true && mounted) {
            messenger.showSnackBar(
              const SnackBar(content: Text('移动完成')),
            );
          }
        case 'preview':
          if (!mounted) return;
          if (entry != null && entry.previewKind != DrivePreviewKind.none) {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => DrivePreviewScreen(
                  sessionId: session.id,
                  entry: entry,
                  remoteDir: session.currentPath,
                ),
              ),
            );
          }
      }
      if (_selectMode && mounted) {
        setState(() {
          _selected.clear();
          _selectMode = false;
        });
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _promptName(String title, String initial) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => _NamePromptDialog(title: title, initial: initial),
    );
  }

  Future<void> _createFolder(DriveSession session) async {
    final name = await _promptName('新建文件夹', '');
    if (name == null || name.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      await context.read<DriveController>().createFolder(session, name.trim());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uploadMenu(DriveSession session) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('相册（可多选）'),
              onTap: () => Navigator.pop(ctx, 'album'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('选择文件'),
              onTap: () => Navigator.pop(ctx, 'files'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    final drive = context.read<DriveController>();
    setState(() => _busy = true);
    try {
      await _ensureConnected(session);
      final paths = <String>[];
      if (action == 'album') {
        final media = await _picker.pickMultipleMedia();
        for (final m in media) {
          paths.add(m.path);
        }
      } else {
        final files = await FilePicker.pickFiles();
        for (final f in files) {
          final path = f.path;
          if (path != null) paths.add(path);
        }
      }
      if (paths.isEmpty) return;
      drive.enqueueUploads(session, paths);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已加入上传队列（${paths.length}）')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onSearch(DriveSession session, String kw) async {
    try {
      await context.read<DriveController>().search(session, kw);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _openSearchHit(DriveSession session, NasSearchHit hit) async {
    final drive = context.read<DriveController>();
    drive.clearSearch(session);
    _searchCtrl.clear();
    await drive.listPath(session, hit.filePath);
    if (hit.isDir) return;
    NasEntry? entry;
    for (final e in session.entries) {
      if (e.name == hit.name) {
        entry = e;
        break;
      }
    }
    entry ??= NasEntry(name: hit.name, isDir: false);
    if (!mounted) return;
    if (entry.previewKind != DrivePreviewKind.none) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DrivePreviewScreen(
            sessionId: session.id,
            entry: entry!,
            remoteDir: hit.filePath,
          ),
        ),
      );
    } else {
      await _showItemActions(session, entry);
    }
  }

  @override
  Widget build(BuildContext context) {
    final drive = context.watch<DriveController>();
    final session = _session(drive);
    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('网盘')),
        body: const Center(child: Text('会话不存在')),
      );
    }

    final dateFmt = DateFormat('yyyy-MM-dd HH:mm');
    final searching = session.searchKeyword.isNotEmpty || session.searching;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(session.displayTitle, style: const TextStyle(fontSize: 17)),
            Text(
              session.connected ? '已连接' : '未连接',
              style: TextStyle(
                fontSize: 12,
                color: session.connected ? const Color(0xFF2E7D32) : Colors.white70,
              ),
            ),
          ],
        ),
        actions: [
          if (_selectMode) ...[
            IconButton(
              tooltip: '下载',
              onPressed: _selected.isEmpty || _busy
                  ? null
                  : () => _runAction(session, _selected.toList(), 'download'),
              icon: const Icon(Icons.download_outlined),
            ),
            IconButton(
              tooltip: '移动',
              onPressed: _selected.isEmpty || _busy
                  ? null
                  : () => _runAction(session, _selected.toList(), 'move'),
              icon: const Icon(Icons.drive_file_move_outline),
            ),
            IconButton(
              tooltip: '删除',
              onPressed: _selected.isEmpty || _busy
                  ? null
                  : () => _runAction(session, _selected.toList(), 'delete'),
              icon: const Icon(Icons.delete_outline),
            ),
            IconButton(
              tooltip: '取消多选',
              onPressed: () => setState(() {
                _selectMode = false;
                _selected.clear();
              }),
              icon: const Icon(Icons.close),
            ),
          ] else ...[
            IconButton(
              tooltip: '多选',
              onPressed: !session.connected
                  ? null
                  : () => setState(() => _selectMode = true),
              icon: const Icon(Icons.checklist),
            ),
            IconButton(
              tooltip: '任务',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DriveTasksScreen(sessionId: session.id),
                  ),
                );
              },
              icon: Badge(
                isLabelVisible: session.activeTaskCount > 0,
                label: Text('${session.activeTaskCount}'),
                child: const Icon(Icons.swap_vert_circle_outlined),
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (v) async {
                switch (v) {
                  case 'connect':
                    try {
                      await drive.connect(session);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text('$e')));
                      }
                    }
                  case 'disconnect':
                    await drive.disconnect(session);
                  case 'mkdir':
                    await _createFolder(session);
                  case 'upload':
                    await _uploadMenu(session);
                  case 'refresh':
                    await drive.refresh(session);
                }
              },
              itemBuilder: (ctx) => [
                if (!session.connected)
                  const PopupMenuItem(value: 'connect', child: Text('连接')),
                if (session.connected)
                  const PopupMenuItem(value: 'disconnect', child: Text('断开')),
                const PopupMenuItem(value: 'refresh', child: Text('刷新')),
                const PopupMenuItem(value: 'mkdir', child: Text('新建文件夹')),
                const PopupMenuItem(value: 'upload', child: Text('上传')),
              ],
            ),
          ],
        ],
      ),
      floatingActionButton: session.connected && !_selectMode
          ? FloatingActionButton(
              heroTag: 'drive-browser-upload-fab',
              onPressed: _busy ? null : () => _uploadMenu(session),
              child: const Icon(Icons.upload),
            )
          : null,
      body: !session.connected
          ? Center(
              child: FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        try {
                          await drive.connect(session);
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context)
                                .showSnackBar(SnackBar(content: Text('$e')));
                          }
                        }
                      },
                icon: const Icon(Icons.link),
                label: const Text('连接网盘'),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Row(
                    children: [
                      if (session.nasInfo != null) ...[
                        NasStorageHeader(info: session.nasInfo!),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: TextField(
                          controller: _searchCtrl,
                          decoration: InputDecoration(
                            hintText: '搜索全盘',
                            prefixIcon: Icon(
                              Icons.search_rounded,
                              size: 20,
                              color: AppTheme.ink.withValues(alpha: 0.4),
                            ),
                            prefixIconConstraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: 40,
                            ),
                            suffixIcon: _searchCtrl.text.isEmpty
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.clear_rounded, size: 18),
                                    onPressed: () {
                                      _searchCtrl.clear();
                                      drive.clearSearch(session);
                                      setState(() {});
                                    },
                                  ),
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.92),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: AppTheme.accent.withValues(alpha: 0.45),
                                width: 1.5,
                              ),
                            ),
                          ),
                          style: const TextStyle(fontSize: 14),
                          textInputAction: TextInputAction.search,
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (v) => _onSearch(session, v),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Material(
                  color: Colors.white.withValues(alpha: 0.55),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 12, 0),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: '上级目录',
                          onPressed:
                              session.currentPath == '/' || session.listing
                              ? null
                              : () => drive.goUp(session),
                          icon: const Icon(Icons.arrow_upward_rounded),
                        ),
                        Expanded(
                          child: Text(
                            session.currentPath,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13.5,
                              color: AppTheme.ink.withValues(alpha: 0.78),
                            ),
                          ),
                        ),
                        if (session.listing || session.searching)
                          const Padding(
                            padding: EdgeInsets.only(left: 8),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (searching)
                  Expanded(child: _buildSearch(session))
                else
                  Expanded(child: _buildList(session, dateFmt)),
              ],
            ),
    );
  }

  Widget _buildSearch(DriveSession session) {
    if (session.searchError.isNotEmpty) {
      return Center(child: Text(session.searchError));
    }
    if (session.searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (session.searchHits.isEmpty) {
      return Center(
        child: Text(
          '无结果',
          style: TextStyle(color: AppTheme.ink.withValues(alpha: 0.45)),
        ),
      );
    }
    return ListView.separated(
      itemCount: session.searchHits.length + (session.searchTruncated ? 1 : 0),
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (session.searchTruncated && index == session.searchHits.length) {
          return const ListTile(
            title: Text('结果过多，已截断', style: TextStyle(fontSize: 13)),
          );
        }
        final hit = session.searchHits[index];
        return ListTile(
          leading: NasFileIcon.forName(hit.name, isDir: hit.isDir),
          title: Text(hit.name),
          subtitle: Text(hit.filePath),
          onTap: () => _openSearchHit(session, hit),
        );
      },
    );
  }

  Widget _buildList(DriveSession session, DateFormat dateFmt) {
    if (session.listError.isNotEmpty) {
      return Center(child: Text(session.listError));
    }
    if (session.entries.isEmpty && !session.listing) {
      return Center(
        child: Text(
          '此目录为空',
          style: TextStyle(color: AppTheme.ink.withValues(alpha: 0.45)),
        ),
      );
    }
    return ListView.separated(
      itemCount: session.entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = session.entries[index];
        final selected = _selected.contains(entry.name);
        final kind = classifyNasName(entry.name, isDir: entry.isDir);
        final subtitle = entry.isDir
            ? kind.label
            : [
                kind.label,
                formatBytes(entry.size),
                if (entry.lastDateMs > 0)
                  dateFmt.format(
                    DateTime.fromMillisecondsSinceEpoch(entry.lastDateMs),
                  ),
              ].join(' · ');
        return ListTile(
          selected: selected,
          leading: _selectMode
              ? Checkbox(
                  value: selected,
                  onChanged: (_) => _toggleSelect(entry.name),
                )
              : NasFileIcon.forName(entry.name, isDir: entry.isDir),
          title: Text(entry.name),
          subtitle: Text(subtitle),
          trailing: entry.isDir ? const Icon(Icons.chevron_right) : null,
          onTap: _busy
              ? null
              : () {
                  if (_selectMode) {
                    _toggleSelect(entry.name);
                  } else {
                    _openEntry(session, entry);
                  }
                },
          onLongPress: _busy
              ? null
              : () {
                  if (_selectMode) {
                    _toggleSelect(entry.name);
                  } else {
                    _showItemActions(session, entry);
                  }
                },
        );
      },
    );
  }
}

class _NamePromptDialog extends StatefulWidget {
  const _NamePromptDialog({required this.title, required this.initial});
  final String title;
  final String initial;

  @override
  State<_NamePromptDialog> createState() => _NamePromptDialogState();
}

class _NamePromptDialogState extends State<_NamePromptDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: const InputDecoration(border: OutlineInputBorder()),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
