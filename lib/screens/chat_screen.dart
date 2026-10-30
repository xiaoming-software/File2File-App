import 'dart:async';
import 'dart:io';

import 'package:file2file/l10n/app_l10n.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import '../models/chat_models.dart';
import '../services/auth_controller.dart';
import '../services/chat_controller.dart';
import '../services/media_save_service.dart';
import '../services/voice_controller.dart';
import '../theme/app_theme.dart';
import '../utils/app_snack.dart';
import '../widgets/message_visibility.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.sessionId});
  final String sessionId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final _textCtrl = TextEditingController();
  final _scroll = ScrollController();
  final _picker = ImagePicker();
  final _saver = MediaSaveService();
  bool _busy = false;

  /// WeChat-like: auto-stick to bottom only when already near the end.
  static const double _nearBottomSlop = 96;
  bool _nearBottom = true;
  bool _showNewMsgTip = false;
  bool _scrollBootstrapped = false;
  String? _lastHandledMsgId;
  int _lastMsgCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScrollPosition);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_healAfterForeground());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.removeListener(_onScrollPosition);
    _textCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScrollPosition() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final near = pos.maxScrollExtent - pos.pixels <= _nearBottomSlop;
    if (near == _nearBottom && !(near && _showNewMsgTip)) {
      if (near) _markSeenIfNearBottom();
      return;
    }
    setState(() {
      _nearBottom = near;
      if (near) _showNewMsgTip = false;
    });
    if (near) _markSeenIfNearBottom();
  }

  void _markSeenIfNearBottom() {
    if (!_isNearBottom()) return;
    final chat = context.read<ChatController>();
    final session = _session(chat);
    if (session == null) return;
    chat.markAllUnseenPeerMessages(session);
  }

  bool _isNearBottom() {
    if (!_scroll.hasClients) return _nearBottom;
    final pos = _scroll.position;
    return pos.maxScrollExtent - pos.pixels <= _nearBottomSlop;
  }

  /// Stick to latest when near bottom / own send; else show「有新消息」.
  void _onMessagesChanged(ChatSession session) {
    final msgs = session.messages;
    final lastId = msgs.isEmpty ? null : msgs.last.id;
    final count = msgs.length;
    if (lastId == _lastHandledMsgId && count == _lastMsgCount) return;

    final prevCount = _lastMsgCount;
    _lastHandledMsgId = lastId;
    _lastMsgCount = count;

    if (!_scrollBootstrapped) {
      _scrollBootstrapped = true;
      _jumpBottom(animated: false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _markSeenIfNearBottom();
      });
      return;
    }
    if (count <= prevCount || msgs.isEmpty) return;

    final last = msgs.last;
    if (last.fromMe || _isNearBottom()) {
      if (_showNewMsgTip) {
        setState(() => _showNewMsgTip = false);
      }
      _jumpBottom();
      // After sticky-bottom layout, mark everything unread as read (reliable).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _markSeenIfNearBottom();
        });
      });
    } else if (!last.fromMe) {
      if (!_showNewMsgTip) setState(() => _showNewMsgTip = true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final chat = context.read<ChatController>();
    if (state == AppLifecycleState.resumed) {
      chat.setAppForeground(true);
      // Skip while gallery/file picker is up — heal races sendFile on Android.
      if (!chat.isMediaPicking) {
        unawaited(_healAfterForeground());
      }
      // Re-entering the app with this chat open → re-send reads.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _markSeenIfNearBottom();
      });
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      chat.setAppForeground(false);
    }
  }

  Future<void> _healAfterForeground() async {
    if (!mounted) return;
    final chat = context.read<ChatController>();
    final auth = context.read<AuthController>();
    final session = _session(chat);
    if (session == null) return;
    try {
      await chat.healAfterForeground(
        session,
        ensureWebrpc: ({bool forceRelogin = false}) =>
            auth.ensureWebrpcAlive(forceRelogin: forceRelogin),
      );
    } catch (e) {
      if (mounted) {
        showAppSnack(context, e);
      }
    }
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
        showAppSnack(context, e);
      }
    }
  }

  void _jumpBottom({bool animated = true}) {
    if (_showNewMsgTip) {
      _showNewMsgTip = false;
      // Avoid setState during build; tip cleared on next frame paint if needed.
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_showNewMsgTip) setState(() {});
        });
      }
    }
    void go() {
      if (!mounted || !_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (animated) {
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      } else {
        _scroll.jumpTo(target);
      }
      _nearBottom = true;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      go();
      // Second frame: image/file bubbles may grow layout after first paint.
      WidgetsBinding.instance.addPostFrameCallback((_) => go());
    });
  }

  void _jumpBottomFromTip() {
    setState(() => _showNewMsgTip = false);
    _jumpBottom();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _markSeenIfNearBottom();
    });
  }

  Future<void> _pickAlbum(ChatSession session, {required bool video}) async {
    final chat = context.read<ChatController>();
    chat.beginMediaPick();
    setState(() => _busy = true);
    try {
      final file = video
          ? await _picker.pickVideo(source: ImageSource.gallery)
          : await _picker.pickImage(source: ImageSource.gallery, imageQuality: 92);
      if (file == null || !mounted) return;
      // Gallery resume used to force-reconnect mid-pick; wait then soft-heal.
      await _ensureConnected(session);
      if (!session.connected || !mounted) return;
      await chat.sendFilePath(session, file.path);
      _jumpBottom();
    } catch (e) {
      if (mounted) {
        showAppSnack(context, e);
      }
    } finally {
      chat.endMediaPick();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickAnyFile(ChatSession session) async {
    final chat = context.read<ChatController>();
    chat.beginMediaPick();
    setState(() => _busy = true);
    try {
      final file = await FilePicker.pickFile();
      final path = file?.path;
      if (path == null || !mounted) return;
      await _ensureConnected(session);
      if (!session.connected || !mounted) return;
      await chat.sendFilePath(session, path);
      _jumpBottom();
    } catch (e) {
      if (mounted) {
        showAppSnack(context, e);
      }
    } finally {
      chat.endMediaPick();
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
              title: Text('语音通话'.tr),
              onTap: () => Navigator.pop(ctx, 'voice'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: Text('相册图片'.tr),
              onTap: () => Navigator.pop(ctx, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: Text('相册视频'.tr),
              onTap: () => Navigator.pop(ctx, 'video'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: Text('选择文件'.tr),
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
        showAppSnack(context, e);
      }
    }
  }

  Future<void> _ensureConnected(ChatSession session) async {
    if (session.connecting) return;
    try {
      final auth = context.read<AuthController>();
      final chat = context.read<ChatController>();
      await chat.healAfterForeground(
        session,
        ensureWebrpc: ({bool forceRelogin = false}) =>
            auth.ensureWebrpcAlive(forceRelogin: forceRelogin),
      );
      if (!session.connected && mounted) {
        showAppSnack(
          context,
          session.connectError.isNotEmpty
              ? session.connectError
              : '连接失败，请重试'.tr,
        );
      }
    } catch (e) {
      if (mounted) {
        showAppSnack(
          context,
          session.connectError.isNotEmpty ? session.connectError : e,
          fallback: '连接失败，请重试'.tr,
        );
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
        showAppSnack(context, e);
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
        appBar: AppBar(title: Text('会话'.tr)),
        body: Center(child: Text('会话不存在'.tr)),
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _onMessagesChanged(session);
    });

    return Scaffold(
      backgroundColor: AppTheme.mist,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(session.displayTitle, style: const TextStyle(fontSize: 17)),
            Text(
              session.connected
                  ? '已连接'.tr
                  : session.connecting
                      ? '连接中…'.tr
                      : '未连接'.tr,
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
              onPressed: (session.connecting || _busy)
                  ? null
                  : () => unawaited(_ensureConnected(session)),
              child: Text(session.connecting ? '连接中…'.tr : '连接'.tr),
            )
          else
            TextButton(
              onPressed: () => chat.disconnect(session),
              child: Text('断开'.tr),
            ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'remark') {
                // reuse sessions tab flow lightly
              } else if (v == 'clear') {
                await chat.clearChat(session);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'clear', child: Text('清空内容'.tr)),
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
            child: Stack(
              children: [
                ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  itemCount: session.messages.length,
                  itemBuilder: (context, index) {
                    final msg = session.messages[index];
                    final ready = msg.filePath.isNotEmpty &&
                        (msg.status == ChatMsgStatus.received ||
                            msg.status == ChatMsgStatus.sent ||
                            msg.fromMe);
                    final bubble = _Bubble(
                      message: msg,
                      peerCapsRead: session.peerCapsRead,
                      onEngage: msg.fromMe
                          ? null
                          : () => chat.confirmPeerMessagesRead(
                                session,
                                [msg.id],
                              ),
                      onRetry: msg.fromMe && msg.status == ChatMsgStatus.failed
                          ? () async {
                              try {
                                await chat.retryMessage(session, msg);
                              } catch (e) {
                                if (context.mounted) showAppSnack(context, e);
                              }
                            }
                          : null,
                      onPreview: ready &&
                              (msg.kind == ChatMsgKind.image ||
                                  msg.kind == ChatMsgKind.video)
                          ? () => _previewMedia(msg)
                          : null,
                      onOpen:
                          ready ? () => OpenFilex.open(msg.filePath) : null,
                      onSaveAlbum: ready &&
                              (msg.kind == ChatMsgKind.image ||
                                  msg.kind == ChatMsgKind.video)
                          ? () => _runSave(() => _saver.saveToAlbum(msg))
                          : null,
                      onSaveDownload: ready
                          ? () =>
                              _runSave(() => _saver.saveToDownloads(msg))
                          : null,
                      onCopy: msg.kind == ChatMsgKind.text
                          ? () async {
                              await Clipboard.setData(
                                ClipboardData(text: msg.content),
                              );
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('已复制'.tr)),
                                );
                              }
                            }
                          : null,
                    );
                    if (msg.fromMe) return bubble;
                    // Re-send type-25 whenever this peer bubble is on screen again.
                    return MessageVisibility(
                      key: ValueKey('vis-${msg.id}'),
                      enabled: true,
                      repeatWhenVisible: true,
                      onVisible: () =>
                          chat.confirmPeerMessagesRead(session, [msg.id]),
                      child: bubble,
                    );
                  },
                ),
                if (_showNewMsgTip)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 10,
                    child: Center(
                      child: Material(
                        color: Colors.white,
                        elevation: 3,
                        shadowColor: Colors.black26,
                        borderRadius: BorderRadius.circular(20),
                        child: InkWell(
                          onTap: _jumpBottomFromTip,
                          borderRadius: BorderRadius.circular(20),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  size: 18,
                                  color: AppTheme.accent,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '有新消息'.tr,
                                  style: TextStyle(
                                    color: AppTheme.accent,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
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
              tooltip: '发送文件'.tr,
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
                  hintText: connected ? '输入消息'.tr : '未连接，先点右上角连接'.tr,
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
    required this.peerCapsRead,
    this.onEngage,
    this.onRetry,
    this.onPreview,
    this.onOpen,
    this.onSaveAlbum,
    this.onSaveDownload,
    this.onCopy,
  });

  final ChatMessage message;
  final bool peerCapsRead;
  /// Peer bubble tap / open — re-send type-25 read receipt.
  final VoidCallback? onEngage;
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
                    onEngage?.call();
                    if (onPreview != null) {
                      onPreview!();
                    } else if (!isFile && onCopy != null) {
                      // no-op tap for text
                    }
                  },
                  onLongPress: () {
                    onEngage?.call();
                    _showActions(context);
                  },
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
                mine
                    ? '$time · ${_statusLabel(message)}'
                    : (isFile ? '$time · ${_statusLabel(message)}' : time),
                style: TextStyle(
                  fontSize: 11,
                  color: AppTheme.ink.withValues(alpha: 0.4),
                ),
              ),
              if (onRetry != null)
                TextButton(
                  onPressed: onRetry,
                  child: Text('重发'.tr),
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
                title: Text('复制'.tr),
                onTap: () {
                  Navigator.pop(ctx);
                  onCopy!();
                },
              ),
            if (isMedia && onSaveAlbum != null)
              ListTile(
                leading: const Icon(Icons.photo_album_outlined),
                title: Text('保存到相册'.tr),
                onTap: () {
                  Navigator.pop(ctx);
                  onSaveAlbum!();
                },
              ),
            if (isMedia && onOpen != null)
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: Text('打开'.tr),
                onTap: () {
                  Navigator.pop(ctx);
                  onOpen!();
                },
              ),
            if (isFile && onSaveDownload != null)
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: Text('保存到下载'.tr),
                onTap: () {
                  Navigator.pop(ctx);
                  onSaveDownload!();
                },
              ),
            if (onRetry != null)
              ListTile(
                leading: const Icon(Icons.refresh),
                title: Text('重发'.tr),
                onTap: () {
                  Navigator.pop(ctx);
                  onRetry!();
                },
              ),
            ListTile(
              leading: const Icon(Icons.close),
              title: Text('取消'.tr),
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
        ChatMsgStatus.sending => '发送中'.tr,
        ChatMsgStatus.failed => '发送失败'.tr,
        // Once persisted as read, always show 已读 (reconnect must not flip UI).
        ChatMsgStatus.read => '已读'.tr,
        // Delivered — unread until peer read receipt; no read cap ⇒ forever unread.
        ChatMsgStatus.sent => '未读'.tr,
        _ => '未读'.tr,
      };
    }
    return switch (m.status) {
      ChatMsgStatus.receiving => '接收中'.tr,
      ChatMsgStatus.received => '接收成功'.tr,
      ChatMsgStatus.failed => '接收失败'.tr,
      _ => '接收成功'.tr,
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
    final transferring = message.status == ChatMsgStatus.sending ||
        message.status == ChatMsgStatus.receiving;
    final bytesDone =
        message.size > 0 && message.transferred >= message.size;
    // Option A: progress only; 发送中/未读/已读 are under the bubble (meta).
    final showBar = transferring && !bytesDone;
    final elapsed = AppL10n.current.fill(
      r'耗时 ${formatDurationMs(message.elapsedMs)} · 平均 ${formatSpeedBps(message.speedBps)}',
      {
        r'${formatDurationMs(message.elapsedMs)}':
            formatDurationMs(message.elapsedMs),
        r'${formatSpeedBps(message.speedBps)}': formatSpeedBps(message.speedBps),
      },
    );
    final xfer =
        '${formatBytes(message.transferred)} / ${formatBytes(message.size)}\n$elapsed';

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
          if (showBar) ...[
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
              if (showBar) ...[
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
