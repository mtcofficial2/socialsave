import 'package:flutter/material.dart';
import 'package:social_save/features/audio/music_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';
import 'package:social_save/features/downloader/presentation/providers/download_manager.dart';
import 'package:social_save/features/library/presentation/library_screen.dart';
import 'package:social_save/features/player/phone_remote.dart';
import 'package:social_save/shared/models/download_status.dart';
import 'package:social_save/features/updates/update_checker.dart';
import 'package:social_save/shared/widgets/brand_header.dart';
import 'package:social_save/shared/widgets/desktop_sidebar.dart';
import 'package:social_save/shared/widgets/page_layout.dart';

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
    final showMini = current != null &&
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
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: _MiniProgress(
                  title: current.title,
                  progress: current.progress,
                  speed: ref.watch(formattersProvider).speed(current.bytesPerSecond),
                  thumbnail: current.thumbnailUrl,
                  onOpen: () => context.push('/progress/${current.id}'),
                  onPause: current.status.canPause
                      ? () => ref.read(downloadManagerProvider.notifier).pause(current.id)
                      : null,
                ),
              ),
            ),
          ),
        if (!wide)
          StitchNavBar(
            index: navigationShell.currentIndex,
            downloadBadge: activeCount,
            onSelect: selectTab,
          ),
      ],
    );

    if (wide) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: Row(
          children: [
            DesktopSidebar(
              index: navigationShell.currentIndex,
              downloadBadge: activeCount,
              onSelect: selectTab,
              onShare: () => context.push('/share'),
              onMusic: () => context.push('/music'),
            ),
            Expanded(
              child: DesktopChrome(
                active: true,
                child: Column(
                  children: [
                    Expanded(child: UpdateChecker(child: TabTransition(index: navigationShell.currentIndex, child: navigationShell))),
                    chrome,
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    // The new Home has its own Send / Receive card and Music tile, so the
    // floating buttons only show there with the Classic home screen.
    final classicHome = ref.watch(settingsControllerProvider.select((s) => s.classicHome));
    // Send / Receive and Music live on Home (and in menus), so the floating
    // buttons only appear with the Classic home screen.
    final hideFab = !classicHome;
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBody: true,
      body: UpdateChecker(child: TabTransition(index: navigationShell.currentIndex, child: navigationShell)),
      floatingActionButton: hideFab ? null : Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            key: const ValueKey('music-fab'),
            heroTag: 'music-fab',
            tooltip: 'Music player',
            onPressed: () => context.push('/music'),
            child: const Icon(Icons.library_music_rounded),
          ),
          const SizedBox(height: 10),
          FloatingActionButton.extended(
            key: const ValueKey('share-hub-fab'),
            heroTag: 'share-fab',
            tooltip: 'Send or receive with nearby devices',
            onPressed: () => context.push('/share'),
            icon: const Icon(Icons.swap_horiz_rounded),
            label: const Text('Send / Receive'),
          ),
        ],
      ),
      bottomNavigationBar: chrome,
    );
  }
}

class _MiniProgress extends StatelessWidget {
  const _MiniProgress({
    required this.title,
    required this.progress,
    required this.speed,
    required this.onOpen,
    this.thumbnail,
    this.onPause,
  });

  final String title;
  final double progress;
  final String speed;
  final String? thumbnail;
  final VoidCallback onOpen;
  final VoidCallback? onPause;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FloatingGlass(
      radius: 24,
      bare: true,
      child: Semantics(
        button: true,
        label: 'Download in progress: $title, ${(progress * 100).round()} percent. Tap to open.',
        onTap: onOpen,
        child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: thumbnail == null || thumbnail!.isEmpty
                      ? ColoredBox(color: scheme.surfaceContainerHigh)
                      : Image.network(thumbnail!, fit: BoxFit.cover),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${(progress * 100).round()}%  •  $speed',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: scheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
              if (onPause != null)
                IconButton(
                  onPressed: onPause,
                  icon: const Icon(Icons.pause_rounded, size: 20),
                ),
              IconButton(
                onPressed: onOpen,
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// Premium tab-switch motion: the incoming tab fades in, slides ~24dp from
/// the side it sits on in the tab order and settles from 0.98 scale. Tabs stay
/// alive in the indexed stack, so scroll positions are preserved, and the nav
/// pill lives outside this widget so it never animates.
class TabTransition extends StatefulWidget {
  const TabTransition({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<TabTransition> createState() => _TabTransitionState();
}

class _TabTransitionState extends State<TabTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    value: 1,
  );
  double _dir = 1;

  @override
  void didUpdateWidget(TabTransition old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      _dir = widget.index > old.index ? 1 : -1;
      if (MediaQuery.disableAnimationsOf(context)) {
        _c.value = 1;
      } else {
        _c.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        if (_c.value >= 1) return child!;
        final t = Curves.easeOutCubic.transform(_c.value);
        final fade = Curves.easeOut.transform((_c.value * 1.6).clamp(0.0, 1.0));
        return Opacity(
          opacity: 0.15 + 0.85 * fade,
          child: Transform.translate(
            offset: Offset(_dir * 24 * (1 - t), 0),
            child: child,
          ),
        );
      },
    );
  }
}