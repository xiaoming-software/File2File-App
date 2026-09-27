import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../models/drive_models.dart';
import '../services/drive_controller.dart';
import '../services/media_save_service.dart';
import '../theme/app_theme.dart';

class DrivePreviewScreen extends StatefulWidget {
  const DrivePreviewScreen({
    super.key,
    required this.sessionId,
    required this.entry,
    required this.remoteDir,
  });

  final String sessionId;
  final NasEntry entry;
  final String remoteDir;

  @override
  State<DrivePreviewScreen> createState() => _DrivePreviewScreenState();
}

class _DrivePreviewScreenState extends State<DrivePreviewScreen> {
  DriveTransfer? _transfer;
  String? _localPath;
  String? _error;
  bool _loading = true;
  final _textCtrl = TextEditingController();
  bool _textDirty = false;
  bool _saving = false;
  VideoPlayerController? _player;
  bool _playerReady = false;
  bool _openingPlayer = false;
  Timer? _poll;
  final _saver = MediaSaveService();

  DrivePreviewKind get _kind => widget.entry.previewKind;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _textCtrl.dispose();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final drive = context.read<DriveController>();
    final session = drive.sessionById(widget.sessionId);
    if (session == null) {
      setState(() {
        _loading = false;
        _error = '会话不存在';
      });
      return;
    }
    try {
      final t = drive.startDownload(
        session,
        widget.entry,
        remoteDir: widget.remoteDir,
      );
      if (!mounted) return;
      _transfer = t;
      _poll = Timer.periodic(const Duration(milliseconds: 400), (_) {
        if (!mounted) return;
        final cur = drive.transferById(session, t.id) ?? t;
        setState(() => _transfer = cur);
        unawaited(_maybeOpen(cur));
      });
      await _maybeOpen(t);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _maybeOpen(DriveTransfer t) async {
    if (t.localPath.isEmpty) return;
    final file = File(t.localPath);
    if (!await file.exists()) return;

    if (_kind == DrivePreviewKind.text) {
      if (t.status != DriveTransferStatus.done) return;
      if (_localPath != null) return;
      final bytes = await file.readAsBytes();
      if (bytes.contains(0)) {
        setState(() {
          _loading = false;
          _error = '不是文本文件';
        });
        return;
      }
      _textCtrl.text = utf8.decode(bytes, allowMalformed: true);
      setState(() {
        _localPath = t.localPath;
        _loading = false;
      });
      _poll?.cancel();
      return;
    }

    if (_kind == DrivePreviewKind.image) {
      if (t.status != DriveTransferStatus.done) return;
      if (_localPath != null) return;
      setState(() {
        _localPath = t.localPath;
        _loading = false;
      });
      _poll?.cancel();
      return;
    }

    if (_kind != DrivePreviewKind.audio && _kind != DrivePreviewKind.video) {
      return;
    }

    final need = widget.entry.size <= 0
        ? 0
        : (widget.entry.size * 0.05).clamp(256 * 1024, 2 * 1024 * 1024).toInt();
    final ready = t.status == DriveTransferStatus.done ||
        (widget.entry.size > 0 && t.transferred >= need);
    if (!ready || _openingPlayer) return;
    if (_playerReady && _localPath == t.localPath) {
      if (t.status == DriveTransferStatus.done) _poll?.cancel();
      return;
    }

    _openingPlayer = true;
    try {
      await _player?.dispose();
      final c = VideoPlayerController.file(File(t.localPath));
      await c.initialize();
      await c.setLooping(true);
      await c.play();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _player = c;
        _playerReady = true;
        _localPath = t.localPath;
        _loading = false;
      });
    } catch (e) {
      if (t.status == DriveTransferStatus.done && mounted) {
        setState(() {
          _loading = false;
          _error = '无法播放：$e';
        });
        _poll?.cancel();
      }
    } finally {
      _openingPlayer = false;
    }
    if (t.status == DriveTransferStatus.done) _poll?.cancel();
  }

  Future<void> _saveText() async {
    final drive = context.read<DriveController>();
    final session = drive.sessionById(widget.sessionId);
    if (session == null) return;
    setState(() => _saving = true);
    try {
      await drive.putTextFile(
        session,
        name: widget.entry.name,
        remoteDir: widget.remoteDir,
        text: _textCtrl.text,
      );
      setState(() => _textDirty = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已保存到网盘')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveAlbum() async {
    final path = _localPath;
    if (path == null) return;
    try {
      final tip = await _saver.savePathToAlbum(
        path,
        video: _kind == DrivePreviewKind.video,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tip)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _transfer;
    final dark = _kind == DrivePreviewKind.image ||
        _kind == DrivePreviewKind.video ||
        _kind == DrivePreviewKind.audio;
    return Scaffold(
      backgroundColor: dark ? Colors.black : null,
      appBar: AppBar(
        title: Text(widget.entry.name),
        actions: [
          if (_kind == DrivePreviewKind.text) ...[
            IconButton(
              tooltip: '复制全部',
              onPressed: _loading
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: _textCtrl.text));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制')),
                        );
                      }
                    },
              icon: const Icon(Icons.copy_all_outlined),
            ),
            TextButton(
              onPressed: !_textDirty || _saving ? null : _saveText,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
          ],
          if ((_kind == DrivePreviewKind.image || _kind == DrivePreviewKind.video) &&
              _localPath != null &&
              t?.status == DriveTransferStatus.done)
            IconButton(
              tooltip: '保存到相册',
              onPressed: _saveAlbum,
              icon: const Icon(Icons.photo_album_outlined),
            ),
        ],
      ),
      body: _buildBody(t),
    );
  }

  Widget _buildBody(DriveTransfer? t) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, style: TextStyle(color: Colors.red.shade300)),
        ),
      );
    }
    if (_loading && !_playerReady && _localPath == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            if (t != null)
              Text(
                '下载中 ${(t.progress * 100).toStringAsFixed(0)}%'
                '${t.size > 0 ? ' · ${formatBytes(t.transferred)}/${formatBytes(t.size)}' : ''}',
                style: TextStyle(color: AppTheme.ink.withValues(alpha: 0.6)),
              ),
          ],
        ),
      );
    }

    switch (_kind) {
      case DrivePreviewKind.text:
        return Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _textCtrl,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            onChanged: (_) {
              if (!_textDirty) setState(() => _textDirty = true);
            },
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '文本内容',
            ),
          ),
        );
      case DrivePreviewKind.image:
        return InteractiveViewer(
          child: Center(
            child: Image.file(File(_localPath!), fit: BoxFit.contain),
          ),
        );
      case DrivePreviewKind.audio:
      case DrivePreviewKind.video:
        if (!_playerReady || _player == null) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
        }
        final isAudio = _kind == DrivePreviewKind.audio;
        return Column(
          children: [
            if (t != null && t.status == DriveTransferStatus.running)
              LinearProgressIndicator(
                value: t.size > 0 ? t.progress : null,
                minHeight: 3,
              ),
            Expanded(
              child: Center(
                child: isAudio
                    ? const Icon(Icons.audiotrack, size: 96, color: Colors.white70)
                    : AspectRatio(
                        aspectRatio: _player!.value.aspectRatio == 0
                            ? 16 / 9
                            : _player!.value.aspectRatio,
                        child: VideoPlayer(_player!),
                      ),
              ),
            ),
            _MediaControls(controller: _player!),
          ],
        );
      case DrivePreviewKind.none:
        return const Center(child: Text('不支持预览'));
    }
  }
}

class _MediaControls extends StatelessWidget {
  const _MediaControls({required this.controller});
  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final pos = value.position;
        final dur = value.duration;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              children: [
                VideoProgressIndicator(
                  controller,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(
                    playedColor: Colors.white,
                    bufferedColor: Colors.white38,
                    backgroundColor: Colors.white24,
                  ),
                ),
                Row(
                  children: [
                    IconButton(
                      onPressed: () {
                        value.isPlaying ? controller.pause() : controller.play();
                      },
                      icon: Icon(
                        value.isPlaying ? Icons.pause_circle : Icons.play_circle,
                        color: Colors.white,
                        size: 36,
                      ),
                    ),
                    Text(
                      '${_fmt(pos)} / ${_fmt(dur)}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    if (h > 0) return '$h:$m:$s';
    return '$m:$s';
  }
}
