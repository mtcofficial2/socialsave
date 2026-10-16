// Pieces of the browser build that stand in for phone/PC-only features.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/downloads/presentation/providers/downloads_controller.dart';
import 'package:social_save/features/player/open_player.dart';
import 'package:social_save/shared/models/download_status.dart';
import 'package:social_save/shared/widgets/platform_logo.dart';
import 'package:social_save/shared/widgets/video_thumbnail.dart';
import 'package:social_save/web/web_saver.dart';

const _apkUrl =
    'https://github.com/mtcofficial2/socialsave/releases/latest/download/SocialSave.apk';
// Newest release that has a Windows build attached.
const _windowsZipUrl =
    'https://github.com/mtcofficial2/socialsave/releases/download/v1.0.23/SocialSave-Windows-1.0.23.zip';

/// Shown on the web where a phone/PC-only feature sits in the apps
/// (Nearby share, the Vault, device folders).
class WebAppsCard extends StatelessWidget {
  const WebAppsCard({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: scheme.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    'App only',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              style: TextStyle(fontSize: 13, height: 1.4, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () => webOpenTab(_apkUrl),
                    icon: const Icon(Icons.android_rounded, size: 18),
                    label: const Text('Android app'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => webOpenTab(_windowsZipUrl),
                    icon: const Icon(Icons.desktop_windows_rounded, size: 18),
                    label: const Text('PC app'),
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

/// Nearby share on the web: a browser cannot find devices on the Wi-Fi or a
/// USB cable, so it points to the apps.
class WebNearbyCard extends StatelessWidget {
  const WebNearbyCard({super.key});

  @override
  Widget build(BuildContext context) {
    return const WebAppsCard(
      icon: Icons.wifi_tethering_rounded,
      title: 'Nearby share',
      detail:
          'Available in the phone and PC apps. They find each other on the same Wi-Fi or over a USB cable and send videos directly.',
    );
  }
}

/// Library on the web: the videos saved from this browser.
class WebLibraryScreen extends ConsumerWidget {
  const WebLibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final rows = ref.watch(downloadsControllerProvider);
    final saved = rows.maybeWhen(
      data: (items) =>
          items.where((r) => r.status == DownloadStatus.completed).toList(),
      orElse: () => const <DownloadRecord>[],
    );
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Text(
              'Library',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Videos saved from this browser. The files are in your browser\'s Downloads folder.',
              style: TextStyle(fontSize: 13, height: 1.4, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            if (rows.isLoading && saved.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (saved.isEmpty)
              _EmptyLibrary(onHome: () => context.go('/'))
            else
              ...saved.map((r) => _LibraryRow(record: r)),
            const SizedBox(height: 16),
            const WebAppsCard(
              icon: Icons.lock_rounded,
              title: 'Vault',
              detail:
                  'The PIN-locked Vault keeps private videos in the phone or PC app\'s own storage, so it is not available in a browser.',
            ),
            const SizedBox(height: 12),
            const WebAppsCard(
              icon: Icons.folder_open_rounded,
              title: 'Device folders',
              detail:
                  'The apps also list the videos already on your phone or PC. A website cannot scan your folders.',
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onHome});

  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(Icons.video_library_rounded, size: 40, color: scheme.primary),
            const SizedBox(height: 8),
            const Text(
              'Nothing saved yet.',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              'Analyze a public link to start.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onHome,
              icon: const Icon(Icons.add_link_rounded),
              label: const Text('Save a video'),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryRow extends StatelessWidget {
  const _LibraryRow({required this.record});

  final DownloadRecord record;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => openInAppPlayer(context, record),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                SizedBox(
                  width: 112,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      VideoThumbnail(
                        url: record.thumbnailUrl,
                        height: 64,
                        borderRadius: 12,
                        durationSeconds: record.durationSeconds,
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          shape: BoxShape.circle,
                        ),
                        padding: const EdgeInsets.all(4),
                        child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 22),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, height: 1.3),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          PlatformLogo(platform: record.platform, size: 14),
                          const SizedBox(width: 6),
                          Text(
                            record.platform.displayName,
                            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(width: 8),
                          Icon(Icons.check_circle_rounded, size: 14, color: scheme.primary),
                          const SizedBox(width: 3),
                          Text(
                            'Saved',
                            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ],
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
