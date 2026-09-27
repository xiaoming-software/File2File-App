import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import '../models/chat_models.dart';
import '../services/chat_controller.dart';
import '../services/media_save_service.dart';
import '../services/voice_controller.dart';
import '../theme/app_theme.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.sessionId});
  final String sessionId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _textCtrl = TextEditingController();
  final _scroll = ScrollController();
  final _picker = ImagePicker();
  final _saver = MediaSaveService();
  bool _busy = false;

  @override
  void dispose() {
    _textCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  ChatSession? _session(ChatController chat) {
    for (final s in chat.sessions) {
      if (s.id == widget.sessionId) return s;
    }
    return null;
  }

  Future<void> _sendText(ChatSession session) async {
    final text = _textCtrl.text;
    if (text.trim().isEmpty) return;
    _textCtrl.clear();
    try {
      await context.read<ChatController>().sendText(session, text);
      _jumpBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  void _jumpBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _pickAlbum(ChatSession session, {required bool video}) async {
    setState(() => _busy = true);
    try {
      final file = video
          ? await _picker.pickVideo(source: ImageSource.gallery)
          : await _picker.pickImage(source: ImageSource.gallery, imageQuality: 92);
      if (file == null || !mounted) return;
      await context.read<ChatController>().sendFilePath(session, file.path);
      _jumpBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickAnyFile(ChatSession session) async {
    setState(() => _busy = true);
    try {
      final file = await FilePicker.pickFile();
      final path = file?.path;
      if (path == null || !mounted) return;
      await context.read<ChatController>().sendFilePath(session, path);
      _jumpBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onAttach(ChatSession session) async {
    if (!session.connected) {
      await _ensureConnected(session);
      if (!session.connected) return;
      if (!mounted) return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.phone_outlined),
              title: const Text('语音通话'),
              onTap: () => Navigator.pop(ctx, 'voice'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('相册图片'),
              onTap: () => Navigator.pop(ctx, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('相册视频'),
              onTap: () => Navigator.pop(ctx, 'video'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('选择文件'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'voice') await _startVoice(session);
    if (action == 'image') await _pickAlbum(session, video: false);
    if (action == 'video') await _pickAlbum(session, video: true);
    if (action == 'file') await _pickAnyFile(session);
  }

  Future<void> _startVoice(ChatSession session) async {
    final voice = context.read<VoiceController>();
    if (!session.connected) {
      await _ensureConnected(session);
      if (!session.connected || !mounted) return;
    }
    try {
      await voice.invite(session);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _ensureConnected(ChatSession session) async {
    if (session.connected) return;
    try {
      await context.read<ChatController>().connect(session);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _runSave(Future<String> Function() action) async {
    try {
      final tip = await action();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tip)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _previewMedia(ChatMessage msg) async {
    if (msg.filePath.isEmpty) return;
    if (msg.kind == ChatMsgKind.video) {
      await OpenFilex.open(msg.filePath);
      return;
    }
    if (msg.kind != ChatMsgKind.image) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black.withValues(alpha: 0.92),
        pageBuilder: (_, _, _) => _ImagePreviewPage(path: msg.filePath, title: msg.title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatController>();
    final session = _session(chat);
    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('会话')),
        body: const Center(child: Text('会话不存在')),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.mist,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(session.displayTitle, style: const TextStyle(fontSize: 17)),
            Text(
              session.connected
                  ? '已连接'
                  : session.connecting
                      ? '连接中…'
                      : '未连接',
              style: TextStyle(
                fontSize: 12,
                color: session.connected ? AppTheme.accent : AppTheme.ink.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
        actions: [
          if (!session.connected)
            TextButton(
              onPressed: _busy ? null : () => _ensureConnected(session),
              child: const Text('连接'),
            )
          else
            TextButton(
              onPressed: () => chat.disconnect(session),
              child: const Text('断开'),
            ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'remark') {
                // reuse sessions tab flow lightly
              } else if (v == 'clear') {
                await chat.clearChat(session);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'clear', child: Text('清空内容')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (session.connectError.isNotEmpty)
            Material(
              color: Colors.red.shade50,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: Colors.red.shade700, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        session.connectError,
                        style: TextStyle(color: Colors.red.shade700, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              itemCount: session.messages.length,
              itemBuilder: (context, index) {
                final msg = session.messages[index];
                final ready = msg.filePath.isNotEmpty &&
                    (msg.status == ChatMsgStatus.received ||
                        msg.status == ChatMsgStatus.sent ||
                        msg.fromMe);
                return _Bubble(
                  message: msg,
                  onRetry: msg.fromMe && msg.status == ChatMsgStatus.failed
                      ? () async {
                          try {
                            await chat.retryMessage(session, msg);
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('$e')),
                              );
                            }
                          }
                        }
                      : null,
                  onPreview: ready &&
                          (msg.kind == ChatMsgKind.image ||
                              msg.kind == ChatMsgKind.video)
                      ? () => _previewMedia(msg)
                      : null,
                  onOpen: ready ? () => OpenFilex.open(msg.filePath) : null,
                  onSaveAlbum: ready &&
                          (msg.kind == ChatMsgKind.image ||
                              msg.kind == ChatMsgKind.video)
                      ? () => _runSave(() => _saver.saveToAlbum(msg))
                      : null,
                  onSaveDownload: ready
                      ? () => _runSave(() => _saver.saveToDownloads(msg))
                      : null,
                  onCopy: msg.kind == ChatMsgKind.text
                      ? () async {
                          await Clipboard.setData(
                            ClipboardData(text: msg.content),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已复制')),
                            );
                          }
                        }
                      : null,
                );
              },
            ),
          ),
          _Composer(
            controller: _textCtrl,
            enabled: !_busy,
            connected: session.connected,
            onSend: () => _sendText(session),
            onAttach: () => _onAttach(session),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.connected,
    required this.onSend,
    required this.onAttach,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool connected;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Material(
      elevation: 8,
      color: Colors.white,
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, 8, 8, 8 + bottom),
        child: Row(
          children: [
            IconButton(
              onPressed: enabled ? onAttach : null,
              icon: const Icon(Icons.add_circle_outline),
              tooltip: '发送文件',
            ),
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => onSend(),
                decoration: InputDecoration(
                  hintText: connected ? '输入消息' : '未连接，先点右上角连接',
                  filled: true,
                  fillColor: AppTheme.mist,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton.filled(
              onPressed: enabled ? onSend : null,
              icon: const Icon(Icons.send_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    this.onRetry,
    this.onPreview,
    this.onOpen,
    this.onSaveAlbum,
    this.onSaveDownload,
    this.onCopy,
  });

  final ChatMessage message;
  final VoidCallback? onRetry;
  final VoidCallback? onPreview;
  final VoidCallback? onOpen;
  final VoidCallback? onSaveAlbum;
  final VoidCallback? onSaveDownload;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final mine = message.fromMe;
    final time = DateFormat('HH:mm:ss').format(message.time);
    final bg = mine ? AppTheme.accent : Colors.white;
    final fg = mine ? Colors.white : AppTheme.ink;
    final isFile = message.kind != ChatMsgKind.text;

    final Widget body;
    if (!isFile) {
      body = Text(message.content, style: TextStyle(color: fg, height: 1.35));
    } else {
      body = _FileCard(message: message, foreground: fg, onMine: mine);
    }

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * (isFile ? 0.82 : 0.78),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(
            crossAxisAlignment:
                mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Material(
                color: bg,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(mine ? 16 : 4),
                  bottomRight: Radius.circular(mine ? 4 : 16),
                ),
                child: InkWell(
                  onTap: () {
                    if (onPreview != null) {
                      onPreview!();
                    } else if (!isFile && onCopy != null) {
                      // no-op tap for text
                    }
                  },
                  onLongPress: () => _showActions(context),
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: isFile ? 10 : 12,
                      vertical: isFile ? 10 : 10,
                    ),
                    child: body,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                isFile ? '$time · ${_statusLabel(message)}' : time,
                style: TextStyle(
                  fontSize: 11,
                  color: AppTheme.ink.withValues(alpha: 0.4),
                ),
              ),
              if (onRetry != null)
                TextButton(
                  onPressed: onRetry,
                  child: const Text('重发'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showActions(BuildContext context) {
    final isMedia = message.kind == ChatMsgKind.image ||
        message.kind == ChatMsgKind.video;
    final isFile = message.kind != ChatMsgKind.text;

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!isFile && onCopy != null)
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('复制'),
                onTap: () {
                  Navigator.pop(ctx);
                  onCopy!();
                },
              ),
            if (isMedia && onSaveAlbum != null)
              ListTile(
                leading: const Icon(Icons.photo_album_outlined),
                title: const Text('保存到相册'),
                onTap: () {
                  Navigator.pop(ctx);
                  onSaveAlbum!();
                },
              ),
            if (isMedia && onOpen != null)
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: const Text('打开'),
                onTap: () {
                  Navigator.pop(ctx);
                  onOpen!();
                },
              ),
            if (isFile && onSaveDownload != null)
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('保存到下载'),
                onTap: () {
                  Navigator.pop(ctx);
                  onSaveDownload!();
                },
              ),
            if (onRetry != null)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('重发'),
                onTap: () {
                  Navigator.pop(ctx);
                  onRetry!();
                },
              ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }

  String _statusLabel(ChatMessage m) {
    if (m.fromMe) {
      return switch (m.status) {
        ChatMsgStatus.sending => '发送中',
        ChatMsgStatus.sent => '发送成功',
        ChatMsgStatus.failed => '发送失败',
        _ => '发送成功',
      };
    }
    return switch (m.status) {
      ChatMsgStatus.receiving => '接收中',
      ChatMsgStatus.received => '接收成功',
      ChatMsgStatus.failed => '接收失败',
      _ => '接收成功',
    };
  }
}

class _FileCard extends StatelessWidget {
  const _FileCard({
    required this.message,
    required this.foreground,
    required this.onMine,
  });

  final ChatMessage message;
  final Color foreground;
  final bool onMine;

  bool get _showImageThumb {
    if (message.kind != ChatMsgKind.image) return false;
    if (message.filePath.isEmpty) return false;
    if (!File(message.filePath).existsSync()) return false;
    if (message.fromMe) return true;
    return message.status == ChatMsgStatus.received;
  }

  @override
  Widget build(BuildContext context) {
    final muted = foreground.withValues(alpha: 0.78);
    final title = truncateUtf8Bytes(message.title, 30);
    final busy = message.status == ChatMsgStatus.sending ||
        message.status == ChatMsgStatus.receiving;
    final moved = message.fromMe ? '已发送' : '已接收';
    final xfer =
        '$moved ${formatBytes(message.transferred)} / ${formatBytes(message.size)}\n'
        '耗时 ${formatDurationMs(message.elapsedMs)} · 平均 ${formatSpeedBps(message.speedBps)}';

    if (_showImageThumb) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ColoredBox(
              color: const Color(0xFF0F1720),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220, maxHeight: 220),
                child: Image.file(
                  File(message.filePath),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => _TypeBadge(
                    kind: message.kind,
                    label: 'IMG',
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: foreground,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            formatBytes(message.size),
            style: TextStyle(color: muted, fontSize: 12),
          ),
          const SizedBox(height: 6),
          Text(xfer, style: TextStyle(color: muted, fontSize: 11.5, height: 1.45)),
          if (busy) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: message.progress,
                minHeight: 4,
                backgroundColor: foreground.withValues(alpha: 0.2),
                color: onMine ? Colors.white : AppTheme.accent,
              ),
            ),
          ],
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TypeBadge(kind: message.kind, label: _badgeLabel(message.kind)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                formatBytes(message.size),
                style: TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 6),
              Text(
                xfer,
                style: TextStyle(color: muted, fontSize: 11.5, height: 1.45),
              ),
              if (busy) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: message.progress,
                    minHeight: 4,
                    backgroundColor: foreground.withValues(alpha: 0.2),
                    color: onMine ? Colors.white : AppTheme.accent,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  String _badgeLabel(ChatMsgKind kind) {
    return switch (kind) {
      ChatMsgKind.image => 'IMG',
      ChatMsgKind.video => 'VID',
      ChatMsgKind.audio => 'AUD',
      _ => 'FILE',
    };
  }
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.kind, required this.label});

  final ChatMsgKind kind;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = switch (kind) {
      ChatMsgKind.image => const Color(0xFF0E9F6E),
      ChatMsgKind.video => const Color(0xFF7A5AF8),
      ChatMsgKind.audio => const Color(0xFFEF6820),
      _ => const Color(0xFF667085),
    };
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
        gradient: kind == ChatMsgKind.video
            ? const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF7A5AF8), Color(0xFF5B3FD6)],
              )
            : null,
      ),
      alignment: Alignment.center,
      child: kind == ChatMsgKind.video
          ? const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 28)
          : Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 11,
                letterSpacing: 0.4,
              ),
            ),
    );
  }
}

class _ImagePreviewPage extends StatelessWidget {
  const _ImagePreviewPage({required this.path, required this.title});

  final String path;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.pop(context),
        child: SafeArea(
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(
                  child: Image.file(File(path), fit: BoxFit.contain),
                ),
              ),
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
