import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/theme/app_colors.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/downloads/presentation/providers/downloads_controller.dart';
import 'package:social_save/features/player/open_player.dart';
import 'package:social_save/shared/widgets/platform_logo.dart';
import 'package:social_save/shared/widgets/video_thumbnail.dart';

class RecentDownloadsSection extends ConsumerWidget {
  const RecentDownloadsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.watch(downloadsControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    return downloads.when(
      loading: () => const SizedBox.shrink(),
      error: (error, _) => Text('Could not load recent downloads: $error'),
      data: (items) {
        final recent = items.take(AppConstants.historyPreviewLimit).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Recent Downloads',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 18,
                      ),
                ),
                const SizedBox(width: 6),
                Container(
                  width: 20,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${recent.length}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: scheme.primary,
                    ),
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => context.go('/downloads'),
                  child: const Text('View All >'),
                ),
              ],
            ),
            if (recent.isEmpty)
              Text(
                'Nothing saved yet. Analyze a public link to start.',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              )
            else
              ...recent.map((record) => _RecentRow(record: record)),
          ],
        );
      },
    );
  }
}

class _RecentRow extends ConsumerWidget {
  const _RecentRow({required this.record});

  final DownloadRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final formatters = ref.watch(formattersProvider);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => context.push('/downloads/${record.id}'),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                SizedBox(
                  width: 72,
                  height: 72,
                  child: VideoThumbnail(
                    url: record.thumbnailUrl,
                    durationSeconds: record.durationSeconds,
                    height: 72,
                    borderRadius: 12,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          PlatformLogo(platform: record.platform, size: 14),
                          const SizedBox(width: 6),
                          Text(
                            record.platform.displayName,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          Text('  •  ', style: TextStyle(color: scheme.onSurfaceVariant)),
                          Text(
                            record.quality ?? 'Video',
                            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        record.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(
                            record.fileSize != null
                                ? formatters.bytes(record.fileSize)
                                : '',
                            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.check_circle, size: 14, color: AppColors.ok),
                          const SizedBox(width: 4),
                          const Text(
                            'Saved',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: AppColors.ok,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Material(
                  color: scheme.surfaceContainerLow,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => openInAppPlayer(context, record),
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: Icon(Icons.play_arrow_rounded, color: scheme.primary),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
