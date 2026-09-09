import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/features/downloader/presentation/providers/download_manager.dart';
import 'package:social_save/features/downloads/presentation/providers/downloads_controller.dart';
import 'package:social_save/shared/models/download_status.dart';
import 'package:social_save/shared/models/download_task.dart';
import 'package:social_save/shared/widgets/error_banner.dart';
import 'package:social_save/shared/widgets/platform_badge.dart';
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
        appBar: AppBar(title: const Text('Download')),
        body: const Center(child: Text('This download is no longer active.')),
      );
    }

    final formatters = ref.watch(formattersProvider);
    final manager = ref.read(downloadManagerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: Text(task.status.label)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          VideoThumbnail(
            url: task.thumbnailUrl,
            durationSeconds: task.durationSeconds,
            height: 180,
          ),
          const SizedBox(height: 16),
          PlatformBadge(platform: task.platform),
          const SizedBox(height: 8),
          Text(
            task.title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 24),
          Center(
            child: SizedBox(
              width: 148,
              height: 148,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CircularProgressIndicator(
                    value: task.downloadUrl.isEmpty || task.totalBytes == null
                        ? null
                        : task.progress,
                    strokeWidth: 8,
                  ),
                  Center(
                    child: Text(
                      formatters.percent(task.progress),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (task.downloadUrl.isEmpty &&
              task.status == DownloadStatus.running) ...[
            const SizedBox(height: 12),
            const Center(child: Text('Preparing the video on the server…')),
          ],
          const SizedBox(height: 24),
          _Metric(
            label: 'Downloaded',
            value:
                '${formatters.bytes(task.receivedBytes)} / ${formatters.bytes(task.totalBytes)}',
          ),
          _Metric(label: 'Speed', value: formatters.speed(task.bytesPerSecond)),
          _Metric(label: 'Remaining', value: formatters.eta(task.eta)),
          _Metric(label: 'Quality', value: task.format.label),
          if (task.errorMessage != null) ...[
            const SizedBox(height: 12),
            ErrorBanner(message: task.errorMessage!),
          ],
          const SizedBox(height: 24),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (task.status.canPause)
                FilledButton.tonalIcon(
                  onPressed: () => manager.pause(task.id),
                  icon: const Icon(Icons.pause_rounded),
                  label: const Text('Pause'),
                ),
              if (task.status.canResume)
                FilledButton.icon(
                  onPressed: () => manager.resume(task.id),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Resume'),
                ),
              if (task.status.canCancel)
                OutlinedButton.icon(
                  onPressed: () => manager.cancel(task.id),
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('Cancel'),
                ),
              if (task.status.canRetry)
                FilledButton.icon(
                  onPressed: () => manager.retry(task.id),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Retry'),
                ),
            ],
          ),
          if (task.status == DownloadStatus.completed) ...[
            const SizedBox(height: 16),
            _CompletedActions(task: task),
          ],
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class _CompletedActions extends ConsumerWidget {
  const _CompletedActions({required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.read(downloadsControllerProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: () async {
            final records = await ref.read(downloadsRepositoryProvider).getAll();
            final record = records.where((item) => item.id == task.id).firstOrNull;
            if (record != null) {
              await history.open(record);
            }
          },
          icon: const Icon(Icons.play_circle_outline),
          label: const Text('Open'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () async {
            final records = await ref.read(downloadsRepositoryProvider).getAll();
            final record = records.where((item) => item.id == task.id).firstOrNull;
            if (record != null) {
              await history.share(record);
            }
          },
          icon: const Icon(Icons.share_outlined),
          label: const Text('Share'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => context.go('/downloads'),
          child: const Text('Go to downloads'),
        ),
      ],
    );
  }
}
