import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/drive_models.dart';
import '../services/drive_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/connection_form_sheet.dart';
import 'drive_browser_screen.dart';

class DrivesTab extends StatelessWidget {
  const DrivesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final drive = context.watch<DriveController>();

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'drives-tab-fab',
        onPressed: () => _showCreate(context),
        icon: const Icon(Icons.add),
        label: const Text('新建网盘'),
      ),
      body: drive.loading
          ? const Center(child: CircularProgressIndicator())
          : drive.sessions.isEmpty
              ? _Empty(onCreate: () => _showCreate(context))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                  itemCount: drive.sessions.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final session = drive.sessions[index];
                    return _DriveTile(
                      session: session,
                      onOpen: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                DriveBrowserScreen(sessionId: session.id),
                          ),
                        );
                      },
                      onMenu: (action) => _onMenu(context, session, action),
                    );
                  },
                ),
    );
  }

  Future<void> _showCreate(BuildContext context) async {
    final result = await showModalBottomSheet<_CreateDriveResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const _CreateDriveSheet(),
    );
    if (result == null || !context.mounted) return;
    final drive = context.read<DriveController>();
    try {
      final session = await drive.createSession(
        peerToken: result.peerToken,
        peerPass: result.peerPass,
        remark: result.remark,
      );
      if (result.connectNow) {
        await drive.connect(session);
      }
      if (!context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DriveBrowserScreen(sessionId: session.id),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _onMenu(
    BuildContext context,
    DriveSession session,
    String action,
  ) async {
    final drive = context.read<DriveController>();
    switch (action) {
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
      case 'remark':
        await _editMeta(context, session);
      case 'delete':
        final ok = await _confirm(context, '删除该网盘会话？本地下载缓存也会清除。');
        if (ok) await drive.deleteSession(session);
    }
  }

  Future<void> _editMeta(BuildContext context, DriveSession session) async {
    final result = await showDialog<_EditDriveMetaResult>(
      context: context,
      builder: (ctx) => _EditDriveMetaDialog(
        initialRemark: session.remark,
        initialPeerPass: session.peerPass,
      ),
    );
    if (result == null || !context.mounted) return;
    await context.read<DriveController>().updateMeta(
          session,
          remark: result.remark,
          peerPass: result.peerPass,
        );
  }

  Future<bool> _confirm(BuildContext context, String text) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return ok == true;
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_outlined, size: 56, color: AppTheme.accent),
            const SizedBox(height: 16),
            Text(
              '还没有网盘',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppTheme.ink,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '添加 mywebdisk-server 的 Token 与口令（须与登录 Token 不同）',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.ink.withValues(alpha: 0.55)),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('新建网盘'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DriveTile extends StatelessWidget {
  const _DriveTile({
    required this.session,
    required this.onOpen,
    required this.onMenu,
  });

  final DriveSession session;
  final VoidCallback onOpen;
  final ValueChanged<String> onMenu;

  @override
  Widget build(BuildContext context) {
    final statusColor = session.connected
        ? const Color(0xFF2E7D32)
        : session.connecting
            ? Colors.orange
            : AppTheme.ink.withValues(alpha: 0.35);
    final statusText = session.connected
        ? '已连接'
        : session.connecting
            ? '连接中…'
            : '未连接';

    return Material(
      color: Colors.white.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: AppTheme.accent.withValues(alpha: 0.12),
                child: Icon(Icons.cloud, color: AppTheme.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.displayTitle,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      statusText,
                      style: TextStyle(color: statusColor, fontSize: 12.5),
                    ),
                    if (session.connectError.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        session.connectError,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.red.shade700,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: onMenu,
                itemBuilder: (ctx) => [
                  if (!session.connected)
                    const PopupMenuItem(value: 'connect', child: Text('连接')),
                  if (session.connected)
                    const PopupMenuItem(value: 'disconnect', child: Text('断开')),
                  const PopupMenuItem(value: 'remark', child: Text('备注/口令')),
                  const PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateDriveResult {
  const _CreateDriveResult({
    required this.peerToken,
    required this.peerPass,
    required this.remark,
    required this.connectNow,
  });
  final String peerToken;
  final String peerPass;
  final String remark;
  final bool connectNow;
}

class _CreateDriveSheet extends StatefulWidget {
  const _CreateDriveSheet();

  @override
  State<_CreateDriveSheet> createState() => _CreateDriveSheetState();
}

class _CreateDriveSheetState extends State<_CreateDriveSheet> {
  final _token = TextEditingController();
  final _pass = TextEditingController();
  final _remark = TextEditingController();
  bool _connectNow = true;

  @override
  void dispose() {
    _token.dispose();
    _pass.dispose();
    _remark.dispose();
    super.dispose();
  }

  void _submit() {
    final token = _token.text.trim();
    if (token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写网盘 Token')),
      );
      return;
    }
    Navigator.pop(
      context,
      _CreateDriveResult(
        peerToken: token,
        peerPass: _pass.text.trim(),
        remark: _remark.text.trim(),
        connectNow: _connectNow,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ConnectionFormSheet(
      icon: Icons.cloud_rounded,
      title: '新建网盘',
      subtitle: '连接 mywebdisk-server；Token 须与当前登录账号不同',
      primaryLabel: _connectNow ? '创建并连接' : '创建',
      onPrimary: _submit,
      children: [
        FormFieldBlock(
          label: '网盘 Token',
          controller: _token,
          hint: '粘贴服务器 Token',
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.next,
          onChanged: (_) => setState(() {}),
        ),
        FormFieldBlock(
          label: '网盘口令',
          controller: _pass,
          hint: '对应 --permission 口令',
          helper: '与服务器启动参数中的 permission 一致',
          textInputAction: TextInputAction.next,
        ),
        FormFieldBlock(
          label: '备注名',
          controller: _remark,
          hint: '例如：办公室 NAS',
          optional: true,
          textInputAction: TextInputAction.done,
        ),
        ConnectNowToggle(
          value: _connectNow,
          onChanged: (v) => setState(() => _connectNow = v),
          subtitle: '创建后立刻连接并打开目录',
        ),
      ],
    );
  }
}

class _EditDriveMetaResult {
  const _EditDriveMetaResult({required this.remark, required this.peerPass});
  final String remark;
  final String peerPass;
}

class _EditDriveMetaDialog extends StatefulWidget {
  const _EditDriveMetaDialog({
    required this.initialRemark,
    required this.initialPeerPass,
  });
  final String initialRemark;
  final String initialPeerPass;

  @override
  State<_EditDriveMetaDialog> createState() => _EditDriveMetaDialogState();
}

class _EditDriveMetaDialogState extends State<_EditDriveMetaDialog> {
  late final TextEditingController _remark;
  late final TextEditingController _pass;

  @override
  void initState() {
    super.initState();
    _remark = TextEditingController(text: widget.initialRemark);
    _pass = TextEditingController(text: widget.initialPeerPass);
  }

  @override
  void dispose() {
    _remark.dispose();
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('备注 / 口令'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _remark,
            decoration: const InputDecoration(labelText: '备注'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _pass,
            decoration: const InputDecoration(labelText: '网盘口令'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _EditDriveMetaResult(
              remark: _remark.text,
              peerPass: _pass.text,
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
