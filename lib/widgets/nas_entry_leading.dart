import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/drive_models.dart';
import '../services/drive_controller.dart';
import 'nas_file_icon.dart';

/// Leading avatar: real thumbnail for image/video when available, else type icon.
///
/// Visible cells call [DriveController.prioritizeThumb] so on-screen items jump
/// the queue. Only this cell rebuilds when *its* thumb path changes.
class NasEntryLeading extends StatefulWidget {
  const NasEntryLeading({
    super.key,
    required this.sessionId,
    required this.entry,
    required this.remoteDir,
    this.size = 44,
    this.showVideoBadge = true,
  });

  final String sessionId;
  final NasEntry entry;
  final String remoteDir;
  final double size;
  final bool showVideoBadge;

  @override
  State<NasEntryLeading> createState() => _NasEntryLeadingState();
}

class _NasEntryLeadingState extends State<NasEntryLeading> {
  DriveController? _drive;
  String? _path;
  bool _wantThumb = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bumpPriority());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final drive = context.read<DriveController>();
    if (!identical(_drive, drive)) {
      _drive?.thumbTick.removeListener(_onThumbTick);
      _drive = drive;
      _drive!.thumbTick.addListener(_onThumbTick);
      _refreshPath(rebuild: false);
    }
  }

  @override
  void didUpdateWidget(covariant NasEntryLeading oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.remoteDir != widget.remoteDir ||
        oldWidget.entry.name != widget.entry.name) {
      _refreshPath(rebuild: true);
      WidgetsBinding.instance.addPostFrameCallback((_) => _bumpPriority());
    }
  }

  @override
  void dispose() {
    _drive?.thumbTick.removeListener(_onThumbTick);
    super.dispose();
  }

  void _onThumbTick() {
    if (!mounted) return;
    final next = _currentPath();
    if (next == _path) return;
    setState(() => _path = next);
  }

  String? _currentPath() {
    final drive = _drive;
    if (drive == null) return null;
    final session = drive.sessionById(widget.sessionId);
    if (session == null) return null;
    return drive.thumbLocalPath(session, widget.remoteDir, widget.entry.name);
  }

  void _refreshPath({required bool rebuild}) {
    final kind = widget.entry.previewKind;
    _wantThumb = !widget.entry.isDir &&
        (kind == DrivePreviewKind.image || kind == DrivePreviewKind.video);
    final next = _wantThumb ? _currentPath() : null;
    if (rebuild && next != _path) {
      setState(() => _path = next);
    } else {
      _path = next;
    }
  }

  void _bumpPriority() {
    if (!mounted || !_wantThumb) return;
    final drive = _drive ?? context.read<DriveController>();
    final session = drive.sessionById(widget.sessionId);
    if (session == null || !session.connected) return;
    drive.prioritizeThumb(session, widget.remoteDir, widget.entry.name);
  }

  @override
  Widget build(BuildContext context) {
    final kind = widget.entry.previewKind;
    if (!_wantThumb) {
      return NasFileIcon.forName(
        widget.entry.name,
        isDir: widget.entry.isDir,
        size: widget.size,
      );
    }

    final path = _path;
    if (path == null || path.isEmpty) {
      return NasFileIcon.forName(
        widget.entry.name,
        isDir: false,
        size: widget.size,
      );
    }

    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cachePx = (widget.size * dpr).round().clamp(48, 384);

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.size * 0.18),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              File(path),
              fit: BoxFit.cover,
              cacheWidth: cachePx,
              cacheHeight: cachePx,
              filterQuality: FilterQuality.low,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => NasFileIcon.forName(
                widget.entry.name,
                isDir: false,
                size: widget.size,
              ),
            ),
            if (widget.showVideoBadge && kind == DrivePreviewKind.video)
              const Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: EdgeInsets.all(3),
                  child: Icon(
                    Icons.play_circle_fill,
                    size: 16,
                    color: Colors.white,
                    shadows: [
                      Shadow(blurRadius: 4, color: Colors.black54),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
