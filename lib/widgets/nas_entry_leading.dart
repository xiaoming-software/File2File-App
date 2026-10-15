import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/drive_models.dart';
import '../services/drive_controller.dart';
import 'nas_file_icon.dart';

/// Leading avatar: real thumbnail for image/video when available, else type icon.
class NasEntryLeading extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final drive = context.watch<DriveController>();
    final session = drive.sessionById(sessionId);
    final kind = entry.previewKind;
    final wantThumb =
        !entry.isDir &&
        (kind == DrivePreviewKind.image || kind == DrivePreviewKind.video);

    if (session == null || !wantThumb) {
      return NasFileIcon.forName(entry.name, isDir: entry.isDir, size: size);
    }

    final path = drive.thumbLocalPath(session, remoteDir, entry.name);
    if (path == null || path.isEmpty) {
      return NasFileIcon.forName(entry.name, isDir: entry.isDir, size: size);
    }

    final file = File(path);
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.18),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              file,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => NasFileIcon.forName(
                entry.name,
                isDir: false,
                size: size,
              ),
            ),
            if (showVideoBadge && kind == DrivePreviewKind.video)
              const Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: EdgeInsets.all(3),
                  child: Icon(
                    Icons.play_circle_fill,
                    size: 16,
                    color: Colors.white,
                    shadows: [Shadow(blurRadius: 4, color: Colors.black54)],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
