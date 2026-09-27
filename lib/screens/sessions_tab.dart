import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/chat_models.dart';
import '../services/auth_controller.dart';
import '../services/chat_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/connection_form_sheet.dart';
import 'chat_screen.dart';

class SessionsTab extends StatelessWidget {
  const SessionsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatController>();
    final account = context.watch<AuthController>().account;
    final token = account?.token ?? '';
    final passphrase = account?.passphrase ?? '';

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'sessions-tab-fab',
        onPressed: () => _showCreate(context),
        icon: const Icon(Icons.add),
        label: const Text('新建会话'),
      ),
      body: chat.loading
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  sliver: SliverToBoxAdapter(
                    child: _MyConnectionCard(
                      token: token,
                      passphrase: passphrase,
                    ),
                  ),
                ),
                if (chat.sessions.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _Empty(onCreate: () => _showCreate(context)),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 100),
                    sliver: SliverList.separated(
                      itemCount: chat.sessions.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final session = chat.sessions[index];
                        return _SessionTile(
                          session: session,
                          onOpen: () {
                            chat.selectSession(session.id);
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    ChatScreen(sessionId: session.id),
                              ),
                            );
                          },
                          onMenu: (action) =>
                              _onMenu(context, session, action),
                        );
                      },
                    ),
                  ),
              ],
            ),
    );
  }

  Future<void> _showCreate(BuildContext context) async {
    final result = await showModalBottomSheet<_CreateResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const _CreateSessionSheet(),
    );
    if (result == null || !context.mounted) return;
    final chat = context.read<ChatController>();
    try {
      final session = await chat.createSession(
        peerToken: result.peerToken,
        peerPass: result.peerPass,
        remark: result.remark,
      );
      if (result.connectNow) {
        await chat.connect(session);
      }
      if (!context.mounted) return;
      chat.selectSession(session.id);
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ChatScreen(sessionId: session.id)),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _onMenu(
    BuildContext context,
    ChatSession session,
    String action,
  ) async {
    final chat = context.read<ChatController>();
    switch (action) {
      case 'connect':
        try {
          await chat.connect(session);
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
          }
        }
      case 'disconnect':
        await chat.disconnect(session);
      case 'remark':
        await _editMeta(context, session);
      case 'clear':
        final ok = await _confirm(context, '清空聊天内容？会话本身会保留。');
        if (ok) await chat.clearChat(session);
      case 'delete':
        final ok = await _confirm(context, '删除该会话及本地聊天记录？');
        if (ok) await chat.deleteSession(session);
    }
  }

  Future<void> _editMeta(BuildContext context, ChatSession session) async {
    final result = await showDialog<_EditMetaResult>(
      context: context,
      builder: (ctx) => _EditSessionMetaDialog(
        initialRemark: session.remark,
        initialPeerPass: session.peerPass,
      ),
    );
    if (result == null || !context.mounted) return;
    await context.read<ChatController>().updateSessionMeta(
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    return ok == true;
  }
}

class _MyConnectionCard extends StatelessWidget {
  const _MyConnectionCard({
    required this.token,
    required this.passphrase,
  });

  final String token;
  final String passphrase;

  String get _bundle {
    final passLine = passphrase.isEmpty ? '（未设置）' : passphrase;
    return 'Token：$token\n认证口令：$passLine';
  }

  Future<void> _copy(BuildContext context, String value, String tip) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tip),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  String _ellipsize(String text, {int head = 10, int tail = 4}) {
    if (text.length <= head + tail + 1) return text;
    return '${text.substring(0, head)}…${text.substring(text.length - tail)}';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(18),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '我的连接信息',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: AppTheme.ink,
                        ),
                  ),
                ),
                TextButton.icon(
                  onPressed: token.isEmpty
                      ? null
                      : () => _copy(context, _bundle, '已复制 Token 和口令'),
                  icon: const Icon(Icons.copy_all_outlined, size: 18),
                  label: const Text('复制全部'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.accent,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '发给对方即可连你（不含 Token 密码）',
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.ink.withValues(alpha: 0.45),
              ),
            ),
            const SizedBox(height: 10),
            _CopyRow(
              label: 'Token',
              value: token.isEmpty ? '—' : _ellipsize(token),
              dimmed: token.isEmpty,
              onCopy: () => _copy(
                context,
                token,
                token.isEmpty ? 'Token 为空' : '已复制 Token',
              ),
            ),
            const SizedBox(height: 6),
            _CopyRow(
              label: '口令',
              value: passphrase.isEmpty
                  ? '未设置'
                  : _ellipsize(passphrase, head: 8, tail: 2),
              dimmed: passphrase.isEmpty,
              onCopy: () => _copy(
                context,
                passphrase,
                passphrase.isEmpty ? '已复制空口令' : '已复制认证口令',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CopyRow extends StatelessWidget {
  const _CopyRow({
    required this.label,
    required this.value,
    required this.onCopy,
    this.dimmed = false,
  });

  final String label;
  final String value;
  final VoidCallback onCopy;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.mist.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onCopy,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.ink.withValues(alpha: 0.5),
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                    color: dimmed
                        ? AppTheme.ink.withValues(alpha: 0.35)
                        : AppTheme.ink,
                  ),
                ),
              ),
              IconButton(
                tooltip: '复制',
                onPressed: onCopy,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.copy_outlined,
                  size: 18,
                  color: AppTheme.accent.withValues(alpha: 0.9),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 56, color: AppTheme.accent.withValues(alpha: 0.8)),
            const SizedBox(height: 16),
            Text(
              '还没有会话',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppTheme.ink,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '添加对方 Token 与认证口令后即可文字聊天、传文件',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.ink.withValues(alpha: 0.65)),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('新建会话'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.onOpen,
    required this.onMenu,
  });

  final ChatSession session;
  final VoidCallback onOpen;
  final void Function(String action) onMenu;

  @override
  Widget build(BuildContext context) {
    final last = session.lastMessage;
    String preview = '暂无消息';
    if (last != null) {
      if (last.kind == ChatMsgKind.text) {
        preview = last.content;
      } else {
        preview = '[${last.title.isEmpty ? last.kind.name : last.title}]';
      }
    }

    return Material(
      color: Colors.white.withValues(alpha: 0.88),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            children: [
              _Avatar(connected: session.connected, connecting: session.connecting),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: AppTheme.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTheme.ink.withValues(alpha: 0.55),
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      session.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: session.connected
                            ? AppTheme.accent
                            : AppTheme.ink.withValues(alpha: 0.4),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                onSelected: onMenu,
                itemBuilder: (ctx) => [
                  if (!session.connected)
                    const PopupMenuItem(value: 'connect', child: Text('连接')),
                  if (session.connected)
                    const PopupMenuItem(value: 'disconnect', child: Text('断开连接')),
                  const PopupMenuItem(value: 'remark', child: Text('备注 / 口令')),
                  const PopupMenuItem(value: 'clear', child: Text('清空内容')),
                  const PopupMenuItem(value: 'delete', child: Text('删除会话')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.connected, required this.connecting});
  final bool connected;
  final bool connecting;

  @override
  Widget build(BuildContext context) {
    final color = connecting
        ? Colors.orange
        : connected
            ? AppTheme.accent
            : AppTheme.ink.withValues(alpha: 0.25);
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(
        connecting ? Icons.sync : Icons.chat_bubble_rounded,
        color: color,
      ),
    );
  }
}

class _EditMetaResult {
  const _EditMetaResult({required this.remark, required this.peerPass});
  final String remark;
  final String peerPass;
}

class _EditSessionMetaDialog extends StatefulWidget {
  const _EditSessionMetaDialog({
    required this.initialRemark,
    required this.initialPeerPass,
  });

  final String initialRemark;
  final String initialPeerPass;

  @override
  State<_EditSessionMetaDialog> createState() => _EditSessionMetaDialogState();
}

class _EditSessionMetaDialogState extends State<_EditSessionMetaDialog> {
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
      title: const Text('会话设置'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _remark,
              decoration: const InputDecoration(labelText: '备注名'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pass,
              decoration: const InputDecoration(labelText: '对方认证口令'),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }

  void _save() {
    Navigator.pop(
      context,
      _EditMetaResult(remark: _remark.text, peerPass: _pass.text),
    );
  }
}

class _CreateResult {
  const _CreateResult({
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

class _CreateSessionSheet extends StatefulWidget {
  const _CreateSessionSheet();

  @override
  State<_CreateSessionSheet> createState() => _CreateSessionSheetState();
}

class _CreateSessionSheetState extends State<_CreateSessionSheet> {
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
        const SnackBar(content: Text('请填写对方 Token')),
      );
      return;
    }
    Navigator.pop(
      context,
      _CreateResult(
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
      icon: Icons.chat_bubble_rounded,
      title: '新建会话',
      subtitle: '填写对方 webrpc Token；若对方设置了认证口令也需一并填写',
      primaryLabel: _connectNow ? '创建并连接' : '创建',
      onPrimary: _submit,
      children: [
        FormFieldBlock(
          label: '对方 Token',
          controller: _token,
          hint: '粘贴对方的 Token',
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.next,
          onChanged: (_) => setState(() {}),
        ),
        FormFieldBlock(
          label: '对方认证口令',
          controller: _pass,
          hint: '对方未设置则可留空',
          optional: true,
          textInputAction: TextInputAction.next,
        ),
        FormFieldBlock(
          label: '备注名',
          controller: _remark,
          hint: '例如：家里电脑',
          optional: true,
          textInputAction: TextInputAction.done,
          onChanged: (_) {},
        ),
        ConnectNowToggle(
          value: _connectNow,
          onChanged: (v) => setState(() => _connectNow = v),
          subtitle: '创建后立刻发起会话连接',
        ),
      ],
    );
  }
}
