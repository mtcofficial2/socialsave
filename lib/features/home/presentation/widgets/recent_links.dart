import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/core/theme/app_tokens.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/downloads/presentation/providers/downloads_controller.dart';
import 'package:social_save/features/home/presentation/providers/home_controller.dart';
import 'package:social_save/shared/widgets/platform_logo.dart';

// Moved from the classic Home screen in 1.0.123.

/// Up to four links the user already saved. A tap fills the field and stays
/// on Home, so the link can be edited before Analyze.
class RecentLinks extends ConsumerWidget {
  const RecentLinks({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref
        .watch(downloadsControllerProvider)
        .maybeWhen(
          data: (rows) => rows,
          orElse: () => const <DownloadRecord>[],
        );
    final links = _uniqueRecentLinks(records);
    if (links.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Recent links',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: links.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final row = links[index];
                final url = row.sourceUrl.trim();
                return Tooltip(
                  message: url,
                  child: Material(
                    color: scheme.surfaceContainerLow,
                    shape: RoundedRectangleBorder(
                      borderRadius: AppRadii.pillAll,
                      side: BorderSide(color: scheme.outlineVariant),
                    ),
                    child: InkWell(
                      key: ValueKey('recent-link-$url'),
                      customBorder: const StadiumBorder(),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        ref.read(homeControllerProvider.notifier).setUrl(url);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            PlatformLogo(platform: row.platform, size: 14),
                            const SizedBox(width: 6),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 168),
                              child: Text(
                                _recentLinkLabel(row),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: scheme.onSurface,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

List<DownloadRecord> _uniqueRecentLinks(List<DownloadRecord> rows) {
  final seen = <String>{};
  final links = <DownloadRecord>[];
  for (final row in rows) {
    final url = row.sourceUrl.trim();
    if (url.isEmpty || !seen.add(url)) continue;
    links.add(row);
    if (links.length == 4) break;
  }
  return links;
}

String _recentLinkLabel(DownloadRecord row) {
  final title = row.title.trim();
  if (title.isNotEmpty && title.toLowerCase() != 'untitled video') return title;
  final host = Uri.tryParse(row.sourceUrl)?.host ?? row.sourceUrl;
  return host.startsWith('www.') ? host.substring(4) : host;
}
