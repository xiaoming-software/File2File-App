import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/drive_models.dart';
import '../services/drive_controller.dart';
import '../theme/app_theme.dart';

class DriveTasksScreen extends StatelessWidget {
  const DriveTasksScreen({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context) {
    final drive = context.watch<DriveController>();
    final session = drive.sessionById(sessionId);
    if (session == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('传输任务')),
        body: const Center(child: Text('会话不存在')),
      );
    }

    final uploads = session.transfers
        .where((t) => t.kind == DriveTransferKind.upload)
        .toList();
    final downloads = session.transfers
        .where((t) => t.kind == DriveTransferKind.download)
        .toList();
    final active = session.activeTaskCount;

    return Scaffold(
      appBar: AppBar(
        title: Text(active > 0 ? '传输任务 ($active)' : '传输任务'),
        actions: [
          TextButton(
            onPressed: session.transfers.isEmpty
                ? null
                : () => drive.clearFinishedTasks(session),
            child: const Text('清除完成'),
          ),
        ],
      ),
      body: session.transfers.isEmpty
          ? Center(
              child: Text(
                '暂无上传/下载任务',
                style: TextStyle(color: AppTheme.ink.withValues(alpha: 0.45)),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                if (uploads.isNotEmpty) ...[
                  _SectionTitle('上传 (${uploads.length})'),
                  ...uploads.map((t) => _TaskCard(session: session, task: t)),
                  const SizedBox(height: 12),
                ],
                if (downloads.isNotEmpty) ...[
                  _SectionTitle('下载 (${downloads.length})'),
                  ...downloads.map((t) => _TaskCard(session: session, task: t)),
                ],
              ],
            ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(
        text,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.session, required this.task});
  final DriveSession session;
  final DriveTransfer task;

  @override
  Widget build(BuildContext context) {
    final drive = context.read<DriveController>();
    final status = switch (task.status) {
      DriveTransferStatus.queued => '排队中',
      DriveTransferStatus.running =>
        '${(task.progress * 100).toStringAsFixed(0)}%'
            '${task.speedBps > 0 ? ' · ${formatBytes(task.speedBps)}/s' : ''}',
      DriveTransferStatus.done => '已完成',
      DriveTransferStatus.failed => '失败',
    };
    final color = switch (task.status) {
      DriveTransferStatus.failed => Colors.red.shade700,
      DriveTransferStatus.done => const Color(0xFF2E7D32),
      DriveTransferStatus.running => AppTheme.accent,
      DriveTransferStatus.queued => AppTheme.ink.withValues(alpha: 0.45),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  task.kind == DriveTransferKind.upload
                      ? Icons.upload_rounded
                      : Icons.download_rounded,
                  size: 20,
                  color: AppTheme.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    task.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (task.status == DriveTransferStatus.failed)
                  IconButton(
                    tooltip: '重试',
                    onPressed: () => drive.retryTransfer(session, task),
                    icon: const Icon(Icons.refresh, size: 20),
                  ),
                if (task.status != DriveTransferStatus.running)
                  IconButton(
                    tooltip: '移除',
                    onPressed: () => drive.removeTask(session, task),
                    icon: const Icon(Icons.close, size: 20),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${task.remoteDir}  ·  $status'
              '${task.size > 0 ? '  ·  ${formatBytes(task.transferred)}/${formatBytes(task.size)}' : ''}',
              style: TextStyle(fontSize: 12, color: color),
            ),
            if (task.error.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                task.error,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: Colors.red.shade700),
              ),
            ],
            if (task.status == DriveTransferStatus.running ||
                task.status == DriveTransferStatus.queued) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: task.status == DriveTransferStatus.queued
                      ? null
                      : (task.size > 0 ? task.progress : null),
                  minHeight: 5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
