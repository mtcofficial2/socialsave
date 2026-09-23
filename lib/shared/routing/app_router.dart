import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/features/downloader/presentation/screens/active_download_screen.dart';
import 'package:social_save/features/downloader/presentation/screens/preview_screen.dart';
import 'package:social_save/features/downloads/presentation/screens/download_detail_screen.dart';
import 'package:social_save/features/downloads/presentation/screens/downloads_screen.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/features/player/presentation/screens/in_app_player_screen.dart';
import 'package:social_save/features/home/presentation/screens/home_screen.dart';
import 'package:social_save/features/library/presentation/library_screen.dart';
import 'package:social_save/features/settings/presentation/screens/about_screen.dart';
import 'package:social_save/features/settings/presentation/screens/legal_screen.dart';
import 'package:social_save/features/settings/presentation/screens/settings_screen.dart';
import 'package:social_save/shared/models/media_info.dart';
import 'package:social_save/shared/routing/app_shell.dart';

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) {
        return AppShell(navigationShell: navigationShell);
      },
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/',
              pageBuilder: (context, state) => const NoTransitionPage(
                child: HomeScreen(),
              ),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/library',
              pageBuilder: (context, state) => const NoTransitionPage(
                child: LibraryScreen(),
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
                  builder: (context, state) => DownloadDetailScreen(
                    id: state.pathParameters['id']!,
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
      path: '/preview',
      builder: (context, state) {
        final extra = state.extra;
        if (extra is String) {
          return PreviewScreen(pendingUrl: extra);
        }
        final media = extra;
        if (media is! MediaInfo) {
          return const Scaffold(
            body: Center(child: Text('No video information was provided.')),
          );
        }
        return PreviewScreen(media: media);
      },
    ),
    GoRoute(
      path: '/progress/:id',
      builder: (context, state) => ActiveDownloadScreen(
        taskId: state.pathParameters['id']!,
      ),
    ),
    GoRoute(
      path: '/legal/privacy',
      builder: (context, state) => const LegalScreen(
        title: 'Privacy policy',
        assetPath: 'assets/legal/privacy_policy.md',
      ),
    ),
    GoRoute(
      path: '/legal/terms',
      builder: (context, state) => const LegalScreen(
        title: 'Terms of service',
        assetPath: 'assets/legal/terms_of_service.md',
      ),
    ),
    GoRoute(
      path: '/about',
      builder: (context, state) => const AboutScreen(),
    ),
    GoRoute(
      path: '/player',
      builder: (context, state) {
        final extra = state.extra;
        if (extra is! PlayerSession) {
          return const Scaffold(
            body: Center(child: Text('Nothing to play.')),
          );
        }
        return InAppPlayerScreen(session: extra);
      },
    ),
  ],
);
