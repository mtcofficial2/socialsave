import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/core/theme/app_colors.dart';
import 'package:social_save/features/downloader/presentation/providers/download_manager.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/downloads/presentation/providers/downloads_controller.dart';
import 'package:social_save/features/home/presentation/providers/home_controller.dart';
import 'package:social_save/features/library/vault_actions.dart';
import 'package:social_save/features/player/open_player.dart';
import 'package:social_save/shared/models/download_status.dart';
import 'package:social_save/shared/widgets/brand_header.dart';
import 'package:social_save/shared/widgets/empty_state.dart';
import 'package:social_save/shared/widgets/platform_logo.dart';
import 'package:social_save/shared/widgets/video_thumbnail.dart';

class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  String _query = '';
  String _filter = 'All';

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(downloadsControllerProvider);
    final active = ref.watch(downloadManagerProvider).active;
    final scheme = Theme.of(context).colorScheme;
    final formatters = ref.watch(formattersProvider);

    return Scaffold(
      body: SafeArea(
        child: history.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text('$error')),
          data: (records) {
            final q = _query.toLowerCase();
            var filtered = records.where((item) {
              if (q.isEmpty) return true;
              return item.title.toLowerCase().contains(q) ||
                  item.platform.displayName.toLowerCase().contains(q);
            }).toList();
            if (_filter == 'Completed') {
              filtered = filtered.where((item) => item.status == DownloadStatus.completed).toList();
            } else if (_filter == 'Audio') {
              filtered = filtered
                  .where((item) => (item.format ?? '').toLowerCase().contains('m4a') ||
                      (item.quality ?? '').toLowerCase().contains('audio'))
                  .toList();
            }
            final showActive = _filter == 'All' || _filter == 'In Progress';
            final empty = filtered.isEmpty && (!showActive || active.isEmpty);

            return Column(
              children: [
                const BrandHeader(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 46,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.search, color: scheme.onSurfaceVariant, size: 20),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  onChanged: (value) => setState(() => _query = value),
                                  decoration: const InputDecoration(
                                    hintText: 'Search downloads, platforms, files...',
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    filled: false,
                                    isDense: true,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                              Icon(Icons.mic_none, color: scheme.onSurfaceVariant, size: 18),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.tune, size: 20),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      _FilterChip(
                        label: 'All',
                        count: '${records.length + active.length}',
                        selected: _filter == 'All',
                        onTap: () => setState(() => _filter = 'All'),
                      ),
                      _FilterChip(
                        label: 'In Progress',
                        count: '${active.length}',
                        highlightCount: true,
                        selected: _filter == 'In Progress',
                        onTap: () => setState(() => _filter = 'In Progress'),
                      ),
                      _FilterChip(
                        label: 'Completed',
                        count: '${records.where((item) => item.status == DownloadStatus.completed).length}',
                        selected: _filter == 'Completed',
                        onTap: () => setState(() => _filter = 'Completed'),
                      ),
                      _FilterChip(
                        label: 'Audio',
                        selected: _filter == 'Audio',
                        onTap: () => setState(() => _filter = 'Audio'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: empty
                      ? const EmptyState(
                          icon: Icons.download_outlined,
                          title: 'No downloads yet',
                          message:
                              'Paste a link like https://www.youtube.com/watch?v=… or a TikTok link, then tap Paste link.',
                        )
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                          children: [
                            if (showActive)
                              ...active.map((task) {
                                final pct = (task.progress * 100).round();
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Card(
                                    child: Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Column(
                                        children: [
                                          Row(
                                            children: [
                                              SizedBox(
                                                width: 72,
                                                height: 72,
                                                child: Stack(
                                                  fit: StackFit.expand,
                                                  children: [
                                                    VideoThumbnail(
                                                      url: task.thumbnailUrl,
                                                      height: 72,
                                                      borderRadius: 12,
                                                    ),
                                                    ColoredBox(
                                                      color: scheme.primary.withValues(alpha: 0.35),
                                                      child: Center(
                                                        child: Text(
                                                          '$pct%',
                                                          style: const TextStyle(
                                                            color: Colors.white,
                                                            fontWeight: FontWeight.w800,
                                                            fontSize: 12,
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Row(
                                                      children: [
                                                        Text(
                                                          task.platform.displayName,
                                                          style: const TextStyle(
                                                            fontWeight: FontWeight.w700,
                                                            fontSize: 11,
                                                          ),
                                                        ),
                                                        const Spacer(),
                                                        Text(
                                                          formatters.speed(task.bytesPerSecond),
                                                          style: TextStyle(
                                                            color: scheme.primary,
                                                            fontWeight: FontWeight.w700,
                                                            fontSize: 12,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      task.title,
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontWeight: FontWeight.w700,
                                                        fontSize: 15,
                                                      ),
                                                    ),
                                                    Text(
                                                      '${formatters.bytes(task.receivedBytes)} / ${formatters.bytes(task.totalBytes)}',
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        color: scheme.onSurfaceVariant,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              Column(
                                                children: [
                                                  IconButton(
                                                    onPressed: task.status.canPause
                                                        ? () => ref
                                                            .read(downloadManagerProvider.notifier)
                                                            .pause(task.id)
                                                        : null,
                                                    icon: const Icon(Icons.pause, size: 18),
                                                  ),
                                                  IconButton(
                                                    onPressed: () => ref
                                                        .read(downloadManagerProvider.notifier)
                                                        .cancel(task.id),
                                                    icon: Icon(Icons.close, size: 18, color: scheme.error),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 12),
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(99),
                                            child: LinearProgressIndicator(
                                              value: task.progress,
                                              minHeight: 6,
                                              color: scheme.primary,
                                              backgroundColor: scheme.surfaceContainerHigh,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              }),
                            ...filtered.map((record) => _HistoryCard(record: record)),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
    this.highlightCount = false,
  });

  final String label;
  final String? count;
  final bool selected;
  final bool highlightCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : scheme.onSurfaceVariant,
                  ),
                ),
                if (count != null) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: highlightCount && !selected
                          ? scheme.secondaryContainer
                          : Colors.white.withValues(alpha: selected ? 0.2 : 0.0),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      count!,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: highlightCount && !selected
                            ? scheme.onSecondaryContainer
                            : selected
                                ? Colors.white
                                : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryCard extends ConsumerWidget {
  const _HistoryCard({required this.record});

  final DownloadRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final formatters = ref.watch(formattersProvider);
    final scheme = Theme.of(context).colorScheme;
    final color = AppColors.platformColor(record.platform);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  GestureDetector(
                    onTap: () => openInAppPlayer(context, record),
                    child: SizedBox(
                      width: 72,
                      height: 72,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          VideoThumbnail(
                            url: record.thumbnailUrl,
                            durationSeconds: record.durationSeconds,
                            height: 72,
                            borderRadius: 12,
                          ),
                          const Center(
                            child: CircleAvatar(
                              radius: 12,
                              backgroundColor: Colors.white70,
                              child: Icon(Icons.play_arrow_rounded, size: 16, color: AppColors.primary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  PlatformLogo(platform: record.platform, size: 14),
                                  const SizedBox(width: 5),
                                  Text(
                                    record.platform.displayName,
                                    style: TextStyle(
                                      color: color,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(Icons.check_circle, size: 14, color: AppColors.ok),
                            const SizedBox(width: 2),
                            Text(
                              record.status.label,
                              style: const TextStyle(
                                color: AppColors.ok,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          record.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                        ),
                        Text(
                          [
                            formatters.relativeDate(record.downloadedAt),
                            if (record.fileSize != null) formatters.bytes(record.fileSize),
                            if (record.quality != null) record.quality,
                            if (record.format != null) record.format!.toUpperCase(),
                          ].join('  •  '),
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (value) => _handle(context, ref, value),
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'open', child: Text('Play')),
                      PopupMenuItem(value: 'vault', child: Text('Move to vault')),
                      PopupMenuItem(value: 'share', child: Text('Share')),
                      PopupMenuItem(value: 'redownload', child: Text('Download again')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.verified, size: 16, color: scheme.primary),
                  const SizedBox(width: 4),
                  Text(
                    'Verified Creative Commons',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                  const Spacer(),
                  _roundIcon(context, Icons.share_outlined, () => _handle(context, ref, 'share')),
                  const SizedBox(width: 6),
                  _roundIcon(context, Icons.open_in_new, () => _handle(context, ref, 'open')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _roundIcon(BuildContext context, IconData icon, VoidCallback onTap) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(width: 32, height: 32, child: Icon(icon, size: 16)),
      ),
    );
  }

  Future<void> _handle(BuildContext context, WidgetRef ref, String value) async {
    final controller = ref.read(downloadsControllerProvider.notifier);
    try {
      switch (value) {
        case 'open':
          await openInAppPlayer(context, record);
        case 'vault':
          await moveDownloadToVault(context, ref, record);
        case 'share':
          await controller.share(record);
        case 'redownload':
          ref.read(homeControllerProvider.notifier).setUrl(record.sourceUrl);
          if (context.mounted) context.go('/');
        case 'delete':
          await controller.delete(record.id, deleteFile: true);
      }
    } on AppException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }
}
