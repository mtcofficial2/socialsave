import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:social_save/features/audio/music_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/features/downloader/presentation/providers/download_manager.dart';
import 'package:social_save/features/library/presentation/vault_lock.dart';
import 'package:social_save/features/player/phone_remote.dart';
import 'package:social_save/shared/models/download_status.dart';
import 'package:social_save/features/updates/update_checker.dart';
import 'package:social_save/shared/widgets/brand_header.dart';
import 'package:social_save/shared/widgets/desktop_sidebar.dart';
import 'package:social_save/shared/widgets/page_layout.dart';
import 'package:social_save/core/theme/app_tokens.dart';
import 'package:social_save/features/chat/chat_history.dart';

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(
      downloadManagerProvider.select((state) => state.current),
    );
    final activeCount = ref.watch(
      downloadManagerProvider.select((state) => state.active.length),
    );
    final showMini =
        current != null &&
        current.status != DownloadStatus.completed &&
        current.status != DownloadStatus.cancelled;

    final wide = isDesktopShell(context);
    void selectTab(int index) {
      if (index != 1) {
        ref.read(vaultUnlockedProvider.notifier).state = false;
      }
      navigationShell.goBranch(
        index,
        initialLocation: index == navigationShell.currentIndex,
      );
    }

    final chrome = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const PhoneRemote(),
        const MiniAudioBar(),
        if (showMini)
          Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
                child: _MiniProgress(
                  title: current.title,
                  progress: current.progress,
                  others: activeCount > 1 ? activeCount - 1 : 0,
                  speed: ref
                      .watch(formattersProvider)
                      .speed(current.bytesPerSecond),
                  thumbnail: current.thumbnailUrl,
                  onOpen: () => context.push('/progress/${current.id}'),
                  onPause: current.status.canPause
                      ? () => ref
                            .read(downloadManagerProvider.notifier)
                            .pause(current.id)
                      : null,
                ),
              ),
            ),
          ),
        if (!wide)
          ValueListenableBuilder<int>(
            valueListenable: ChatHistory.unreadTotal,
            builder: (context, unread, _) => StitchNavBar(
              index: navigationShell.currentIndex,
              downloadBadge: activeCount,
              moreBadge: unread,
              onSelect: selectTab,
            ),
          ),
      ],
    );

    if (wide) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Row(
          children: [
            ValueListenableBuilder<int>(
              valueListenable: ChatHistory.unreadTotal,
              builder: (context, unread, _) => DesktopSidebar(
                index: navigationShell.currentIndex,
                downloadBadge: activeCount,
                moreBadge: unread,
                onSelect: selectTab,
              ),
            ),
            Expanded(
              child: DesktopChrome(
                active: true,
                child: Column(
                  children: [
                    Expanded(
                      child: UpdateChecker(
                        child: TabTransition(
                          index: navigationShell.currentIndex,
                          child: navigationShell,
                        ),
                      ),
                    ),
                    chrome,
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      body: UpdateChecker(
        child: TabTransition(
          index: navigationShell.currentIndex,
          child: navigationShell,
        ),
      ),
      // One shared backdrop for the nav pill and the download pill.
      bottomNavigationBar: BackdropGroup(child: chrome),
    );
  }
}

class _MiniProgress extends StatelessWidget {
  const _MiniProgress({
    required this.title,
    required this.progress,
    required this.speed,
    this.others = 0,
    required this.onOpen,
    this.thumbnail,
    this.onPause,
  });

  final String title;
  final double progress;
  final String speed;
  final int others;
  final String? thumbnail;
  final VoidCallback onOpen;
  final VoidCallback? onPause;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = context.tokens;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.4,
      child: FloatingGlass(
      radius: AppRadii.xl,
      bare: true,
      child: Semantics(
        button: true,
        label:
            'Download in progress: $title, ${(progress * 100).round()} percent. Tap to open.',
        onTap: onOpen,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: AppRadii.smAll,
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: thumbnail == null || thumbnail!.isEmpty
                        ? ColoredBox(color: scheme.surfaceContainerHigh)
                        : CachedNetworkImage(
                            imageUrl: thumbnail!,
                            fit: BoxFit.cover,
                            memCacheWidth: 120,
                            fadeInDuration: Duration.zero,
                            fadeOutDuration: Duration.zero,
                            errorWidget: (_, _, _) => ColoredBox(color: scheme.surfaceContainerHigh),
                          ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.itemSubtitle.copyWith(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                      Text(
                        others > 0
                            ? '${(progress * 100).round()}%  •  $speed  •  ${others + 1} at once'
                            : '${(progress * 100).round()}%  •  $speed',
                        // 1.0.49: accent text on light glass fell under 4.5:1.
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.caption.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.72),
                        ),
                      ),
                    ],
                  ),
                ),
                if (onPause != null)
                  IconButton(
                    tooltip: 'Pause download',
                    onPressed: onPause,
                    icon: const Icon(Icons.pause_rounded, size: 20),
                  ),
                IconButton(
                  tooltip: 'Open download',
                  onPressed: onOpen,
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}

/// Tab body. The indexed stack keeps each tab alive, so scroll positions stay.
/// The switch itself is instant: sliding this whole subtree made every glass
/// surface resample for the length of the animation. The nav pill still travels.
class TabTransition extends StatelessWidget {
  const TabTransition({super.key, required int index, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
