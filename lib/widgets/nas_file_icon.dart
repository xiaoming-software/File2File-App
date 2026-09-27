import 'package:flutter/material.dart';

import '../models/nas_file_kind.dart';

/// Colored rounded icon matching Desktop `.nas-icon` styles.
class NasFileIcon extends StatelessWidget {
  const NasFileIcon({
    super.key,
    required this.kind,
    this.size = 28,
  });

  factory NasFileIcon.forName(
    String name, {
    Key? key,
    bool isDir = false,
    double size = 28,
  }) {
    return NasFileIcon(
      key: key,
      kind: classifyNasName(name, isDir: isDir),
      size: size,
    );
  }

  final NasFileKind kind;
  final double size;

  static const _colors = <NasFileKind, Color>{
    NasFileKind.folder: Color(0xFF5AC8FA),
    NasFileKind.image: Color(0xFF34C759),
    NasFileKind.video: Color(0xFFAF52DE),
    NasFileKind.audio: Color(0xFFFF2D55),
    NasFileKind.pdf: Color(0xFFFF3B30),
    NasFileKind.archive: Color(0xFFFF9F0A),
    NasFileKind.doc: Color(0xFF007AFF),
    NasFileKind.text: Color(0xFF64D2FF),
    NasFileKind.code: Color(0xFF5856D6),
    NasFileKind.file: Color(0xFF8E8E93),
  };

  static IconData _glyph(NasFileKind kind) => switch (kind) {
        NasFileKind.folder => Icons.folder,
        NasFileKind.image => Icons.image,
        NasFileKind.video => Icons.videocam,
        NasFileKind.audio => Icons.music_note,
        NasFileKind.pdf => Icons.picture_as_pdf,
        NasFileKind.archive => Icons.inventory_2,
        NasFileKind.doc => Icons.description,
        NasFileKind.text => Icons.article,
        NasFileKind.code => Icons.code,
        NasFileKind.file => Icons.insert_drive_file,
      };

  @override
  Widget build(BuildContext context) {
    final bg = _colors[kind] ?? _colors[NasFileKind.file]!;
    final glyphSize = size * (16 / 28);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(size * (7 / 28)),
      ),
      alignment: Alignment.center,
      child: Icon(
        _glyph(kind),
        size: glyphSize,
        color: Colors.white,
      ),
    );
  }
}
