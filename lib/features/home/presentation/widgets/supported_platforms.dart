import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/shared/models/platform_catalog.dart';
import 'package:social_save/shared/widgets/platform_badge.dart';

class SupportedPlatformsSection extends ConsumerWidget {
  const SupportedPlatformsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(platformCatalogProvider);
    return catalog.when(
      data: (items) => _PlatformGrid(items: items),
      loading: () => _PlatformGrid(items: PlatformCapability.fallbackCatalog()),
      error: (_, _) =>
          _PlatformGrid(items: PlatformCapability.fallbackCatalog()),
    );
  }
}

class _PlatformGrid extends StatelessWidget {
  const _PlatformGrid({required this.items});

  final List<PlatformCapability> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Supported platforms',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 6),
        Text(
          'Public videos can be saved from these sources. Private, login-only, and DRM-protected clips are skipped.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: items.map((item) {
            return FilterChip(
              avatar: PlatformBadge(platform: item.platform, compact: true),
              label: Text(item.platform.displayName),
              selected: item.enabled,
              onSelected: null,
              tooltip: _tooltip(item),
            );
          }).toList(),
        ),
      ],
    );
  }

  String _tooltip(PlatformCapability item) {
    if (!item.enabled) {
      return '${item.platform.displayName} is disabled.';
    }
    if (item.supportsDownload) {
      return 'Metadata and permitted downloads are available.';
    }
    if (item.supportsMetadata) {
      return 'Metadata only. Direct download is not offered unless the platform allows it.';
    }
    return item.notes ?? item.platform.displayName;
  }
}
