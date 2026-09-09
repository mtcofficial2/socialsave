import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/features/downloader/presentation/providers/download_manager.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/downloads/presentation/providers/downloads_controller.dart';
import 'package:social_save/features/home/presentation/providers/home_controller.dart';
import 'package:social_save/shared/widgets/empty_state.dart';
import 'package:social_save/shared/widgets/platform_badge.dart';
import 'package:social_save/shared/widgets/video_thumbnail.dart';

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(downloadsControllerProvider);
    final active = ref.watch(downloadManagerProvider).active;
    final formatters = ref.watch(formattersProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        actions: [
          IconButton(
            tooltip: 'Clear history',
            onPressed: () => _confirmClear(context, ref),
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: history.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (records) {
          if (records.isEmpty && active.isEmpty) {
            return const EmptyState(
              icon: Icons.download_outlined,
              title: 'No downloads yet',
              message: 'Analyze a public video URL to start your first save.',
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              if (active.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(
                    'In progress',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ...active.map((task) {
                  return ListTile(
                    leading: const Icon(Icons.downloading_rounded),
                    title: Text(task.title, maxLines: 1),
                    subtitle: LinearProgressIndicator(value: task.progress),
                    trailing: Text(formatters.percent(task.progress)),
                    onTap: () => context.push('/progress/${task.id}'),
                  );
                }),
              ],
              if (records.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    'History',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ...records.map((record) => _DownloadTile(record: record)),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear download history?'),
        content: const Text(
          'This removes history from the app. You can also delete the saved files.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear history'),
          ),
        ],
      ),
    );
    if (result == true) {
      await ref.read(downloadsControllerProvider.notifier).clear(deleteFiles: false);
    }
  }
}

class _DownloadTile extends ConsumerWidget {
  const _DownloadTile({required this.record});

  final DownloadRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final formatters = ref.watch(formattersProvider);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: SizedBox(
        width: 72,
        child: VideoThumbnail(
          url: record.thumbnailUrl,
          height: 56,
          borderRadius: 10,
        ),
      ),
      title: Text(record.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Row(
            children: [
              PlatformBadge(platform: record.platform, compact: true),
              const SizedBox(width: 8),
              Text(formatters.relativeDate(record.downloadedAt)),
            ],
          ),
          Text(
            [
              if (record.fileSize != null) formatters.bytes(record.fileSize),
              if (record.quality != null) record.quality,
              record.status.label,
            ].join(' · '),
          ),
        ],
      ),
      onTap: () => context.push('/downloads/${record.id}'),
      trailing: PopupMenuButton<String>(
        onSelected: (value) => _handle(context, ref, value),
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'open', child: Text('Open')),
          PopupMenuItem(value: 'share', child: Text('Share')),
          PopupMenuItem(value: 'redownload', child: Text('Download again')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }

  Future<void> _handle(
    BuildContext context,
    WidgetRef ref,
    String value,
  ) async {
    final controller = ref.read(downloadsControllerProvider.notifier);
    try {
      switch (value) {
        case 'open':
          await controller.open(record);
        case 'share':
          await controller.share(record);
        case 'redownload':
          ref.read(homeControllerProvider.notifier).setUrl(record.sourceUrl);
          if (context.mounted) {
            context.go('/');
          }
        case 'delete':
          await controller.delete(record.id, deleteFile: true);
      }
    } on AppException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    }
  }
}
