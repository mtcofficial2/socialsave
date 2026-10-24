import 'package:animations/animations.dart';
import 'package:social_save/features/audio/music_screen.dart';
import 'package:flutter/material.dart';
import 'package:social_save/features/home/presentation/screens/browse_screen.dart';
import 'package:social_save/features/status/hd_status_screen.dart';
import 'package:social_save/features/library/share_hub.dart';
import 'package:social_save/shared/routing/onboarding.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/features/player/desktop_pip.dart';
import 'package:social_save/features/downloader/presentation/screens/active_download_screen.dart';
import 'package:social_save/features/downloader/presentation/screens/playlist_screen.dart';
import 'package:social_save/features/downloader/presentation/screens/preview_screen.dart';
import 'package:social_save/features/downloads/presentation/screens/download_detail_screen.dart';
import 'package:social_save/features/downloads/presentation/screens/downloads_screen.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/features/player/presentation/screens/in_app_player_screen.dart';
import 'package:social_save/features/home/presentation/screens/home_screen_v2.dart';
import 'package:social_save/features/library/presentation/library_screen.dart';
import 'package:social_save/features/library/presentation/library_screen_v2.dart';
import 'package:social_save/features/settings/presentation/screens/about_screen.dart';
import 'package:social_save/features/settings/presentation/screens/legal_screen.dart';
import 'package:social_save/features/settings/presentation/screens/settings_screen.dart';
import 'package:social_save/shared/models/media_info.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/shared/routing/app_shell.dart';
import 'package:social_save/features/home/presentation/widgets/link_offer.dart';
import 'package:social_save/features/settings/presentation/screens/background_detect_screen.dart';
import 'package:social_save/shared/widgets/glass.dart';
import 'package:social_save/shared/widgets/windows_drop_zone.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:social_save/web/web_library.dart';

/// Set before runApp by the `--open <path>` test switch.
String debugInitialLocation = '/';

/// Set by the --open-vault test switch: Library starts on the Vault tab.
bool debugOpenVault = false;

/// Set by --open-menu: Library opens the first video's menu (screenshots).
bool debugOpenMenu = false;

/// Set by --dock-first: Library plays the first video docked (tests).
bool debugDockFirst = false;

/// Pushed pages. The wallpaper stays still and only the content slides a
/// short distance. Fading the whole page allocated a full-screen layer and
/// made every open feel late, especially over the glass surfaces.
Page<void> _page(GoRouterState state, Widget child, {bool modal = false}) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: const Duration(milliseconds: 180),
    reverseTransitionDuration: const Duration(milliseconds: 140),
    opaque: true,
    barrierColor: null,
    transitionsBuilder: (context, animation, secondary, child) {
      final wallpaper = const GlassBackground();
      if (MediaQuery.disableAnimationsOf(context)) {
        return Stack(fit: StackFit.expand, children: [wallpaper, child]);
      }
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return Stack(
        fit: StackFit.expand,
        children: [
          wallpaper,
          SlideTransition(
            position: Tween<Offset>(
              begin: modal ? const Offset(0, 0.02) : const Offset(0.03, 0),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        ],
      );
    },
  );
}
final appRouter = GoRouter(
  initialLocation: debugInitialLocation,
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) {
        // Under the PC mini player the pages keep their full-window layout.
        final shell = DesktopPip.holdLayout(
          context,
          LinkOfferWatcher(child: OnboardingGate(child: AppShell(navigationShell: navigationShell))),
        );
        // Windows: drop videos or link shortcuts anywhere on the window.
        if (Plat.isWindows) return WindowsDropZone(child: shell);
        return shell;
      },
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/',
              pageBuilder: (context, state) => const NoTransitionPage(
                child: HomeGate(),
              ),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/library',
              pageBuilder: (context, state) => const NoTransitionPage(
                child: kIsWeb ? WebLibraryScreen() : LibraryGate(),
              ),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/downloads',
              pageBuilder: (context, state) => const NoTransitionPage(
                child: DownloadsScreen(),
              ),
              routes: [
                GoRoute(
                  path: ':id',
                  pageBuilder: (context, state) => _page(
                    state,
                    DownloadDetailScreen(id: state.pathParameters['id']!),
                  ),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              pageBuilder: (context, state) => const NoTransitionPage(
                child: SettingsScreen(),
              ),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/browse',
      pageBuilder: (context, state) => _page(
        state,
        BrowseScreen(initialUrl: state.extra is String ? state.extra as String : null),
      ),
    ),
    GoRoute(
      path: '/status',
      pageBuilder: (context, state) => _page(state, const HdStatusScreen()),
    ),
    GoRoute(
      path: '/background-detect',
      pageBuilder: (context, state) => _page(state, const BackgroundDetectScreen()),
    ),
    GoRoute(
      path: '/music',
      pageBuilder: (context, state) => _page(state, const MusicScreen()),
    ),
    GoRoute(
      path: '/share',
      pageBuilder: (context, state) => _page(state, const ShareHubScreen(), modal: true),
    ),
    GoRoute(
      path: '/playlist',
      pageBuilder: (context, state) {
        final extra = state.extra;
        return _page(state, PlaylistScreen(url: extra is String ? extra : ''), modal: true);
      },
    ),
    GoRoute(
      path: '/preview',
      pageBuilder: (context, state) {
        final extra = state.extra;
        if (extra is String) {
          return _page(state, PreviewScreen(pendingUrl: extra), modal: true);
        }
        final media = extra;
        if (media is! MediaInfo) {
          return _page(state, const Scaffold(
            body: Center(child: Text('No video information was provided.')),
          ));
        }
        return _page(state, PreviewScreen(media: media), modal: true);
      },
    ),
    GoRoute(
      path: '/progress/:id',
      pageBuilder: (context, state) => _page(
        state,
        ActiveDownloadScreen(taskId: state.pathParameters['id']!),
        modal: true,
      ),
    ),
    GoRoute(
      path: '/legal/privacy',
      pageBuilder: (context, state) => _page(state, const LegalScreen(
        title: 'Privacy policy',
        assetPath: 'assets/legal/privacy_policy.md',
      )),
    ),
    GoRoute(
      path: '/legal/terms',
      pageBuilder: (context, state) => _page(state, const LegalScreen(
        title: 'Terms of service',
        assetPath: 'assets/legal/terms_of_service.md',
      )),
    ),
    GoRoute(
      path: '/about',
      pageBuilder: (context, state) => _page(state, const AboutScreen()),
    ),
    GoRoute(
      path: '/player',
      pageBuilder: (context, state) {
        final extra = state.extra;
        if (extra is WebPlayerArgs) return _page(state, WebPlayerScreen(args: extra), modal: true);
        if (extra is! PlayerSession) {
          return _page(state, const Scaffold(
            body: Center(child: Text('Nothing to play.')),
          ));
        }
        return _page(state, InAppPlayerScreen(session: extra), modal: true);
      },
    ),
  ],
);
