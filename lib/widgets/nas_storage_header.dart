import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/drive_models.dart';
import '../theme/app_theme.dart';

/// One-line storage chip — keeps list space; tap for full breakdown.
class NasStorageHeader extends StatelessWidget {
  const NasStorageHeader({super.key, required this.info});

  final NasInfo info;

  static ({int used, int free, int total, double ratio, int pct}) _calc(
    NasInfo info,
  ) {
    final total = info.diskSize;
    final free = info.banlenSize < 0 ? 0 : info.banlenSize;
    final used = total > free ? total - free : 0;
    final ratio = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    return (
      used: used,
      free: free,
      total: total,
      ratio: ratio,
      pct: (ratio * 100).round(),
    );
  }

  static Color _barColor(int pct) => switch (pct) {
        >= 95 => const Color(0xFFFF453A),
        >= 80 => const Color(0xFFFF9F0A),
        _ => AppTheme.accent,
      };

  Future<void> _showDetails(BuildContext context) async {
    final c = _calc(info);
    final fileLabel = NumberFormat('#,###').format(info.fileNum);
    final bar = _barColor(c.pct);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '存储空间',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.ink.withValues(alpha: 0.92),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      formatBytes(c.used),
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.6,
                        height: 1,
                        color: AppTheme.ink,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '/ ${formatBytes(c.total)}',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppTheme.ink.withValues(alpha: 0.45),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${c.pct}%',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: c.pct >= 80
                            ? bar
                            : AppTheme.ink.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    value: c.ratio,
                    minHeight: 8,
                    backgroundColor: AppTheme.ink.withValues(alpha: 0.08),
                    color: bar,
                  ),
                ),
                const SizedBox(height: 16),
                _DetailRow(label: '剩余', value: formatBytes(c.free)),
                _DetailRow(label: '文件数', value: fileLabel),
                if (c.pct >= 80) ...[
                  const SizedBox(height: 8),
                  Text(
                    c.pct >= 95 ? '空间将满，建议清理文件' : '空间紧张',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: bar,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = _calc(info);
    final bar = _barColor(c.pct);
    final label =
        '已用 ${formatBytes(c.used)}，共 ${formatBytes(c.total)}，剩余 ${formatBytes(c.free)}';

    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: '剩余 ${formatBytes(c.free)} · 点按查看详情',
        child: Material(
          color: Colors.white.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: () => _showDetails(context),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              constraints: const BoxConstraints(minWidth: 96, maxWidth: 128),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${formatBytes(c.used)}/${formatBytes(c.total)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                      color: AppTheme.ink.withValues(alpha: 0.82),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 5),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      value: c.ratio,
                      minHeight: 3.5,
                      backgroundColor: AppTheme.ink.withValues(alpha: 0.08),
                      color: bar,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: AppTheme.ink.withValues(alpha: 0.45),
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppTheme.ink.withValues(alpha: 0.88),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
