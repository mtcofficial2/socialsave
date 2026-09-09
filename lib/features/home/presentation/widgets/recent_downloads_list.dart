import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/downloads/presentation/providers/downloads_controller.dart';
import 'package:social_save/shared/widgets/platform_badge.dart';
import 'package:social_save/shared/widgets/video_thumbnail.dart';

class RecentDownloadsSection extends ConsumerWidget {
  const RecentDownloadsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.watch(downloadsControllerProvider);
    return downloads.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Text('Could not load recent downloads: $error'),
      data: (items) {
        if (items.isEmpty) {
          return const SizedBox.shrink();
        }
        final recent = items.take(AppConstants.historyPreviewLimit).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Recent downloads',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => context.go('/downloads'),
                  child: const Text('See all'),
                ),
              ],
            ),
            SizedBox(
              height: 168,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: recent.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  return _RecentCard(record: recent[index]);
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RecentCard extends ConsumerWidget {
  const _RecentCard({required this.record});

  final DownloadRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final formatters = ref.watch(formattersProvider);
    return SizedBox(
      width: 220,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => context.push('/downloads/${record.id}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            VideoThumbnail(
              url: record.thumbnailUrl,
              durationSeconds: record.durationSeconds,
              height: 110,
              borderRadius: 14,
            ),
            const SizedBox(height: 8),
            Text(
              record.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            Row(
              children: [
                PlatformBadge(platform: record.platform, compact: true),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    formatters.relativeDate(record.downloadedAt),
                    style: Theme.of(context).textTheme.labelSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
