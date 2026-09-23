import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/theme/app_colors.dart';
import 'package:social_save/features/downloader/presentation/providers/download_manager.dart';
import 'package:social_save/features/downloads/presentation/providers/downloads_controller.dart';
import 'package:social_save/features/player/open_player.dart';
import 'package:social_save/shared/models/download_status.dart';
import 'package:social_save/shared/models/download_task.dart';
import 'package:social_save/shared/widgets/brand_header.dart';
import 'package:social_save/shared/widgets/glass.dart';
import 'package:social_save/core/utils/formatters.dart';
import 'package:social_save/shared/widgets/platform_logo.dart';
import 'package:social_save/shared/widgets/video_thumbnail.dart';

class ActiveDownloadScreen extends ConsumerWidget {
  const ActiveDownloadScreen({super.key, required this.taskId});

  final String taskId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final task = ref.watch(
      downloadManagerProvider.select((state) => state.byId(taskId)),
    );
    if (task == null) {
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              const BrandHeader(showBack: true, title: 'Downloading Media'),
              const Expanded(child: Center(child: Text('This download is no longer active.'))),
            ],
          ),
        ),
      );
    }

    final formatters = ref.watch(formattersProvider);
    final manager = ref.read(downloadManagerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    final queued = ref.watch(downloadManagerProvider).active.where((item) => item.id != task.id).toList();
    final pct = (task.progress * 100).round();

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            const BrandHeader(),
            Row(
              children: [
                const Text(
                  'Downloading Media',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
                const Spacer(),
                CircleAvatar(
                  backgroundColor: scheme.surfaceContainer,
                  child: IconButton(
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            GlassCard(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  Container(
                    height: 4,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          AppColors.secondaryContainer,
                          AppColors.primary,
                          AppColors.secondary,
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 80,
                              height: 80,
                              child: Stack(
                                children: [
                                  VideoThumbnail(
                                    url: task.thumbnailUrl,
                                    height: 80,
                                    borderRadius: 12,
                                  ),
                                  Positioned(
                                    left: 6,
                                    bottom: 6,
                                    child: PlatformLogo(platform: task.platform, size: 18),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Wrap(
                                    spacing: 6,
                                    children: [
                                      _pill(context, task.format.quality),
                                      _pill(context, task.format.format.toUpperCase()),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    task.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (task.author != null)
                                    Text(
                                      '@${task.author}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Text(
                              '$pct%',
                              style: TextStyle(
                                fontSize: 34,
                                fontWeight: FontWeight.w800,
                                color: scheme.primary,
                                letterSpacing: -1,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${formatters.bytes(task.receivedBytes)} / ${formatters.bytes(task.totalBytes)}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: LinearProgressIndicator(
                            value: task.status == DownloadStatus.running ? task.progress : task.progress,
                            minHeight: 10,
                            backgroundColor: scheme.surfaceContainerHigh,
                            color: scheme.primary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            _speedLine(task, formatters),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: SizedBox(
                                height: 52,
                                child: FilledButton.tonalIcon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: scheme.surfaceContainer,
                                    foregroundColor: scheme.primary,
                                  ),
                                  onPressed: task.status.canPause
                                      ? () => manager.pause(task.id)
                                      : task.status.canResume
                                          ? () => manager.resume(task.id)
                                          : null,
                                  icon: Icon(
                                    task.status.canResume
                                        ? Icons.play_arrow_rounded
                                        : Icons.pause_rounded,
                                  ),
                                  label: Text(task.status.canResume ? 'Resume' : 'Pause'),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: SizedBox(
                                height: 52,
                                child: FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: scheme.errorContainer,
                                    foregroundColor: scheme.onErrorContainer,
                                  ),
                                  onPressed: task.status.canCancel
                                      ? () {
                                          manager.cancel(task.id);
                                          Navigator.maybePop(context);
                                        }
                                      : null,
                                  icon: const Icon(Icons.close_rounded),
                                  label: const Text('Cancel'),
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (task.status == DownloadStatus.failed &&
                            task.errorMessage != null) ...[
                          const SizedBox(height: 12),
                          _FailureCard(
                            message: task.errorMessage!,
                            onRetry: () => manager.retry(task.id),
                          ),
                        ],
                        if (task.status == DownloadStatus.completed) ...[
                          const SizedBox(height: 12),
                          _CompletedRow(task: task),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (queued.isNotEmpty) ...[
              const SizedBox(height: 20),
              Row(
                children: [
                  const Text(
                    'Next in Queue',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  const SizedBox(width: 8),
                  CircleAvatar(
                    radius: 10,
                    backgroundColor: scheme.surfaceContainer,
                    child: Text('${queued.length}', style: const TextStyle(fontSize: 11)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ...queued.map(
                (item) => GlassCard(
                  child: ListTile(
                    leading: SizedBox(
                      width: 56,
                      height: 56,
                      child: VideoThumbnail(
                        url: item.thumbnailUrl,
                        height: 56,
                        borderRadius: 12,
                      ),
                    ),
                    title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${item.format.quality} • ${formatters.bytes(item.totalBytes)}',
                    ),
                    trailing: const Icon(Icons.drag_handle),
                    onTap: () => context.push('/progress/${item.id}'),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _pill(BuildContext context, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: scheme.primary,
        ),
      ),
    );
  }
}

String _speedLine(DownloadTask task, Formatters formatters) {
  final preparing = task.status == DownloadStatus.queued ||
      (task.status == DownloadStatus.running &&
          task.receivedBytes == 0 &&
          task.bytesPerSecond <= 0);
  if (preparing) return 'Preparing on your computer';
  if (task.status == DownloadStatus.paused) return 'Paused';
  if (task.bytesPerSecond <= 0) return 'Starting the save…';
  return '${formatters.speed(task.bytesPerSecond)} · about ${formatters.eta(task.eta)} left';
}

String _failureTitle(String message) {
  final lower = message.toLowerCase();
  if (lower.contains('asleep') || lower.contains('same wi-fi')) {
    return 'Computer is not reachable';
  }
  if (lower.contains('no longer available') || lower.contains('removed')) {
    return 'This video was removed';
  }
  if (lower.contains('private') ||
      lower.contains('login') ||
      lower.contains('not allow') ||
      lower.contains('members-only')) {
    return 'This video is private';
  }
  if (lower.contains('offline')) return 'No connection';
  if (lower.contains('too long') || lower.contains('timed out')) {
    return 'This took too long';
  }
  if (lower.contains('storage')) return 'Not enough space';
  return 'Could not save this video';
}

class _FailureCard extends StatelessWidget {
  const _FailureCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _failureTitle(message),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: scheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            message,
            style: TextStyle(
              fontSize: 13,
              height: 1.35,
              color: scheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
              ),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompletedRow extends ConsumerWidget {
  const _CompletedRow({required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.read(downloadsControllerProvider.notifier);
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () async {
              final records = await ref.read(downloadsRepositoryProvider).getAll();
              final record = records.where((item) => item.id == task.id).firstOrNull;
              if (record != null) await history.share(record);
            },
            icon: const Icon(Icons.ios_share),
            label: const Text('Share'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.icon(
            onPressed: () async {
              final records = await ref.read(downloadsRepositoryProvider).getAll();
              final record = records.where((item) => item.id == task.id).firstOrNull;
              if (record != null && context.mounted) {
                await openInAppPlayer(context, record);
              }
            },
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Play'),
          ),
        ),
      ],
    );
  }
}
