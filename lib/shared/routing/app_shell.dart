import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/features/downloader/presentation/providers/download_manager.dart';
import 'package:social_save/features/library/presentation/library_screen.dart';
import 'package:social_save/features/player/phone_remote.dart';
import 'package:social_save/shared/models/download_status.dart';
import 'package:social_save/features/updates/update_checker.dart';
import 'package:social_save/shared/widgets/brand_header.dart';
import 'package:social_save/shared/widgets/glass.dart';

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

    final wide = MediaQuery.sizeOf(context).width >= 1100;
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
        if (showMini)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
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
            NavigationRail(
              selectedIndex: navigationShell.currentIndex,
              onDestinationSelected: selectTab,
              labelType: NavigationRailLabelType.all,
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home_rounded),
                  label: Text('Home'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.video_library_outlined),
                  selectedIcon: Icon(Icons.video_library_rounded),
                  label: Text('Library'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.download_outlined),
                  selectedIcon: Icon(Icons.download_rounded),
                  label: Text('Downloads'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.tune_outlined),
                  selectedIcon: Icon(Icons.tune_rounded),
                  label: Text('Settings'),
                ),
              ],
            ),
            Expanded(
              child: Column(
                children: [
                  Expanded(child: UpdateChecker(child: navigationShell)),
                  chrome,
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: UpdateChecker(child: navigationShell),
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
    return Glass(
      borderRadius: 22,
      blur: true,
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
                        fontSize: 11,
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
    );
  }
}
