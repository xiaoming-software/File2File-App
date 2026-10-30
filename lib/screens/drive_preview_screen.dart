import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file2file/l10n/app_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

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
  static const _playerOpenTimeout = Duration(seconds: 15);

  DriveController? _drive;
  DriveTransfer? _transfer;
  String? _localPath;
  String? _error;
  bool _loading = true;
  final _textCtrl = TextEditingController();
  bool _textDirty = false;
  bool _saving = false;

  Player? _mkPlayer;
  VideoController? _mkVideo;
  StreamSubscription<String>? _mkErrorSub;
  bool _playerReady = false;
  bool _openingPlayer = false;
  /// HTTP stream failed once → fall back to SendFile local (do not loop).
  bool _httpFallbackTried = false;
  bool _playingHttp = false;
  Timer? _poll;
  final _saver = MediaSaveService();

  DrivePreviewKind get _kind => widget.entry.previewKind;

  bool get _isMedia =>
      _kind == DrivePreviewKind.audio || _kind == DrivePreviewKind.video;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _drive ??= context.read<DriveController>();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _textCtrl.dispose();
    unawaited(_disposePlayer());

    final drive = _drive;
    final t = _transfer;
    if (drive != null && t != null) {
      final session = drive.sessionById(widget.sessionId);
      if (session != null) {
        drive.releasePreviewDownload(session, t);
      }
    }
    super.dispose();
  }

  Future<void> _disposePlayer() async {
    await _mkErrorSub?.cancel();
    _mkErrorSub = null;
    final mk = _mkPlayer;
    _mkPlayer = null;
    _mkVideo = null;
    if (mk != null) {
      try {
        await mk.dispose();
      } catch (_) {}
    }
    _playerReady = false;
  }

  Future<void> _start() async {
    final drive = context.read<DriveController>();
    _drive = drive;
    final session = drive.sessionById(widget.sessionId);
    if (session == null) {
      setState(() {
        _loading = false;
        _error = '会话不存在'.tr;
      });
      return;
    }
    // Video/audio: mpv (media_kit) over HTTP proxy first; on failure → SendFile local.
    if (_isMedia && !_httpFallbackTried) {
      final url = drive.mediaStreamUrl(
        session,
        widget.remoteDir,
        widget.entry.name,
      );
      if (url != null && url.isNotEmpty) {
        try {
          await _openWithMediaKitNetwork(url);
          if (!mounted) return;
          setState(() {
            _playerReady = true;
            _localPath = url;
            _playingHttp = true;
            _loading = false;
            _error = null;
          });
          return;
        } catch (e) {
          await _disposePlayer();
          debugPrint('drive preview http/mpv failed: $e');
          _httpFallbackTried = true;
          _playingHttp = false;
        }
      }
    }
    await _startSendFilePreview(drive, session);
  }

  Future<void> _startSendFilePreview(
    DriveController drive,
    DriveSession session,
  ) async {
    try {
      final t = await drive.startDownload(
        session,
        widget.entry,
        remoteDir: widget.remoteDir,
        forPreview: true,
      );
      if (!mounted) {
        drive.releasePreviewDownload(session, t);
        return;
      }
      _transfer = t;
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(milliseconds: 400), (_) {
        if (!mounted) return;
        final cur = drive.transferById(session, t.id) ?? t;
        setState(() => _transfer = cur);
        if (cur.status == DriveTransferStatus.failed ||
            cur.status == DriveTransferStatus.cancelled) {
          setState(() {
            _loading = false;
            _error = cur.error.isEmpty ? '下载失败'.tr : cur.error;
          });
          _poll?.cancel();
          return;
        }
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

  Future<void> _fallbackHttpToSendFile() async {
    if (_httpFallbackTried) return;
    _httpFallbackTried = true;
    _playingHttp = false;
    await _disposePlayer();
    if (!mounted) return;
    setState(() {
      _loading = true;
      _playerReady = false;
      _error = null;
      _localPath = null;
    });
    final drive = _drive ?? context.read<DriveController>();
    final session = drive.sessionById(widget.sessionId);
    if (session == null) return;
    await _startSendFilePreview(drive, session);
  }

  Future<void> _openWithMediaKitNetwork(String url) async {
    _openingPlayer = true;
    try {
      await _disposePlayer();
      final player = Player();
      final video = VideoController(player);
      _mkPlayer = player;
      _mkVideo = video;
      _playingHttp = true;
      _mkErrorSub = player.stream.error.listen((msg) {
        if (!mounted || msg.trim().isEmpty) return;
        // Mid-stream decode/format failure → SendFile local via mpv.
        if (_playingHttp && !_httpFallbackTried) {
          unawaited(_fallbackHttpToSendFile());
          return;
        }
        setState(() {
          _loading = false;
          _playerReady = false;
          _error = AppL10n.current.fill(r'无法播放：$msg', {r'$msg': msg});
        });
      });
      await player.open(Media(url), play: true).timeout(_playerOpenTimeout);
      await player.setPlaylistMode(PlaylistMode.loop);
    } finally {
      _openingPlayer = false;
    }
  }

  Future<void> _retryOpen() async {
    setState(() {
      _error = null;
      _loading = true;
      _playerReady = false;
      _localPath = null;
      _openingPlayer = false;
      _httpFallbackTried = false;
      _playingHttp = false;
    });
    await _disposePlayer();
    _poll?.cancel();
    _transfer = null;
    await _start();
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
          _error = '不是文本文件'.tr;
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

    if (!_isMedia) return;

    // Wait until download finishes; do not require NAS size == local size
    // (metadata size can be wrong and would leave UI stuck on "正在打开").
    if (t.status != DriveTransferStatus.done) return;
    if (_openingPlayer) return;
    if (_playerReady && _localPath == t.localPath) {
      _poll?.cancel();
      return;
    }

    final len = await file.length();
    if (len <= 0) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '下载内容为空（可能未真正拉取文件），请点重试'.tr;
        });
        _poll?.cancel();
      }
      return;
    }

    _openingPlayer = true;
    if (mounted) setState(() => _loading = true);
    try {
      await _disposePlayer();
      // Local SendFile path: mpv (media_kit) only — best format coverage.
      await _openWithMediaKit(t.localPath);
      if (!mounted) {
        await _disposePlayer();
        return;
      }
      setState(() {
        _playerReady = true;
        _localPath = t.localPath;
        _playingHttp = false;
        _loading = false;
        _error = null;
      });
      _poll?.cancel();
    } catch (e) {
      await _disposePlayer();
      if (mounted) {
        setState(() {
          _loading = false;
          _playerReady = false;
          _error = AppL10n.current.fill(r'无法播放：$e', {r'$e': '$e'});
        });
        _poll?.cancel();
      }
    } finally {
      _openingPlayer = false;
    }
  }

  Future<void> _openWithMediaKit(String path) async {
    final player = Player();
    final video = VideoController(player);
    _mkPlayer = player;
    _mkVideo = video;
    _mkErrorSub = player.stream.error.listen((msg) {
      if (!mounted || msg.trim().isEmpty) return;
      setState(() {
        _loading = false;
        _playerReady = false;
        _error = AppL10n.current.fill(r'无法播放：$msg', {r'$msg': msg});
      });
      _poll?.cancel();
    });
    // Try both URI forms; some iOS builds prefer one over the other.
    Object? err;
    for (final src in [Uri.file(path).toString(), path]) {
      try {
        await player.open(Media(src), play: true).timeout(_playerOpenTimeout);
        err = null;
        break;
      } catch (e) {
        err = e;
      }
    }
    if (err != null) throw err;
    await player.setPlaylistMode(PlaylistMode.loop);
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
          SnackBar(content: Text('已保存到网盘'.tr)),
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
              tooltip: '复制全部'.tr,
              onPressed: _loading
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: _textCtrl.text));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已复制'.tr)),
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
                  : Text('保存'.tr),
            ),
          ],
          if ((_kind == DrivePreviewKind.image || _kind == DrivePreviewKind.video) &&
              _localPath != null &&
              t?.status == DriveTransferStatus.done)
            IconButton(
              tooltip: '保存到相册'.tr,
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.red.shade300),
              ),
              if (_isMedia) ...[
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _retryOpen,
                  child: Text('重试打开'.tr),
                ),
              ],
            ],
          ),
        ),
      );
    }
    if (_loading && !_playerReady && _localPath == null) {
      final downloading = t != null &&
          (t.status == DriveTransferStatus.queued ||
              t.status == DriveTransferStatus.running);
      final opening = t?.status == DriveTransferStatus.done;
      final lightText = _kind == DrivePreviewKind.video ||
          _kind == DrivePreviewKind.audio ||
          _kind == DrivePreviewKind.image;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              opening
                  ? '正在打开…'.tr
                  : downloading
                      ? (t.status == DriveTransferStatus.queued
                          ? '排队下载中…'.tr
                          : '正在下载…'.tr)
                      : '准备中…'.tr,
              style: TextStyle(
                color: lightText
                    ? Colors.white70
                    : AppTheme.ink.withValues(alpha: 0.6),
              ),
            ),
            if (t != null && downloading) ...[
              const SizedBox(height: 8),
              Text(
                '${(t.progress * 100).toStringAsFixed(0)}%'
                '${t.size > 0 ? ' · ${formatBytes(t.transferred)}/${formatBytes(t.size)}' : ''}'
                '${t.speedBps > 0 ? ' · ${formatBytes(t.speedBps)}/s' : ''}',
                style: TextStyle(
                  color: lightText
                      ? Colors.white54
                      : AppTheme.ink.withValues(alpha: 0.45),
                ),
              ),
            ],
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
            decoration: InputDecoration(
              border: OutlineInputBorder(),
              hintText: '文本内容'.tr,
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
        if (!_playerReady) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
        }
        final isAudio = _kind == DrivePreviewKind.audio;
        final mk = _mkPlayer;
        final video = _mkVideo;
        if (mk == null || video == null) {
          return const Center(
            child: CircularProgressIndicator(color: Colors.white),
          );
        }
        return Column(
          children: [
            Expanded(
              child: isAudio
                  ? const Center(
                      child: Icon(Icons.audiotrack, size: 96, color: Colors.white70),
                    )
                  : Video(
                      controller: video,
                      controls: NoVideoControls,
                      fill: Colors.black,
                    ),
            ),
            _MediaKitControls(player: mk),
          ],
        );
      case DrivePreviewKind.none:
        return Center(child: Text('不支持预览'.tr));
    }
  }
}

class _MediaKitControls extends StatelessWidget {
  const _MediaKitControls({required this.player});
  final Player player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: player.stream.playing,
      initialData: player.state.playing,
      builder: (context, playingSnap) {
        return StreamBuilder<Duration>(
          stream: player.stream.position,
          initialData: player.state.position,
          builder: (context, posSnap) {
            return StreamBuilder<Duration>(
              stream: player.stream.duration,
              initialData: player.state.duration,
              builder: (context, durSnap) {
                final playing = playingSnap.data ?? false;
                final pos = posSnap.data ?? Duration.zero;
                final dur = durSnap.data ?? Duration.zero;
                final maxMs = dur.inMilliseconds <= 0 ? 1 : dur.inMilliseconds;
                final value = (pos.inMilliseconds / maxMs).clamp(0.0, 1.0);
                return SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Column(
                      children: [
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                          ),
                          child: Slider(
                            value: value.toDouble(),
                            onChanged: (v) {
                              player.seek(
                                Duration(milliseconds: (v * maxMs).round()),
                              );
                            },
                          ),
                        ),
                        Row(
                          children: [
                            IconButton(
                              onPressed: () {
                                playing ? player.pause() : player.play();
                              },
                              icon: Icon(
                                playing ? Icons.pause_circle : Icons.play_circle,
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
          },
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
