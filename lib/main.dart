import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/features/downloader/presentation/providers/download_manager.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/app.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/network/windows_dns_fallback.dart';
import 'package:social_save/core/notifications/notification_service.dart';
import 'package:social_save/core/storage/hive_init.dart';
import 'package:social_save/features/downloads/data/datasources/download_history_store.dart';
import 'package:social_save/features/library/phone_handoff.dart';
import 'package:social_save/features/library/presentation/library_screen.dart';
import 'package:social_save/features/library/vault_service.dart';
import 'package:social_save/features/settings/data/datasources/settings_store.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/routing/app_router.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Test hook: a sender with no UI and no database, so it can run next to
  // the normal app on the same PC. `SocialSave.exe --send-only <file>`
  // `--drop-only` waits for a pushed video; `--push-only <file> <code>` sends one.
  if (args.contains('--drop-only')) {
    final code = await PhoneHandoff.openDrop();
    print('debug drop code=$code');
    PhoneHandoff.drop.addListener(() {
      final v = PhoneHandoff.drop.value;
      if (v == null) return;
      print('debug drop ${v.received}/${v.total} busy=${v.busy} failed=${v.failed} file=${v.file?.path}');
      if (!v.busy) Future<void>.delayed(const Duration(seconds: 2), () => exit(v.file == null ? 1 : 0));
    });
    await Future<void>.delayed(PhoneHandoff.lifetime);
    exit(2);
  }
  final po = args.indexOf('--push-only');
  if (po >= 0 && po + 2 < args.length) {
    var last = -1;
    final err = await PhoneHandoff.push(File(args[po + 1]), args[po + 2], onProgress: (s, t) {
      final pct = t > 0 ? s * 100 ~/ t : 0;
      if (pct ~/ 25 != last) {
        last = pct ~/ 25;
        print('debug push $pct%');
      }
    });
    print('debug push result=${err ?? 'ok'}');
    exit(err == null ? 0 : 1);
  }
  final so = args.indexOf('--send-only');
  if (so >= 0 && so + 1 < args.length) {
    final offer = await PhoneHandoff.offer(File(args[so + 1]));
    // ignore: avoid_print
    print('debug send-only code=${offer?.code} url=${offer?.url}');
    await Future<void>.delayed(PhoneHandoff.lifetime);
    exit(0);
  }
  WindowsDnsFallback.install();
  MediaKit.ensureInitialized();

  final box = await const HiveInit().openDownloadsBox();
  final prefs = await SharedPreferences.getInstance();
  final settingsStore = SharedPreferencesSettingsStore(prefs);
  final settings = await settingsStore.load();
  final notifications = NotificationService();
  await notifications.init();

  runApp(
    ProviderScope(
      overrides: [
        downloadsRepositoryProvider.overrideWithValue(
          HiveDownloadHistoryStore(box),
        ),
        settingsRepositoryProvider.overrideWithValue(settingsStore),
        initialSettingsProvider.overrideWithValue(settings),
        notificationServiceProvider.overrideWithValue(notifications),
        vaultServiceProvider.overrideWithValue(VaultService(prefs)),
      ],
      child: const SocialSaveApp(),
    ),
  );

  // Desktop test hook: `SocialSave.exe --download <url>` runs the normal
  // analyze + save flow and prints each step.
  final dl = args.indexOf('--download');
  if (dl >= 0 && dl + 1 < args.length) {
    final url = args[dl + 1];
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future<void>.delayed(const Duration(seconds: 3));
      final ctx = appRouter.routerDelegate.navigatorKey.currentContext;
      if (ctx == null) return;
      final c = ProviderScope.containerOf(ctx, listen: false);
      // ignore_for_file: avoid_print
      try {
        print('debug analyze $url');
        final media = await c.read(mediaRepositoryProvider).analyze(url);
        print('debug formats ${media.formats.map((f) => f.id).toList()}');
        final task = await c.read(downloadManagerProvider.notifier).enqueue(
              media: media,
              format: media.formats.first,
            );
        print('debug enqueued ${task.id} -> ${task.localPath}');
        for (var i = 0; i < 150; i++) {
          await Future<void>.delayed(const Duration(seconds: 2));
          final t = c.read(downloadManagerProvider).byId(task.id);
          print('debug status ${t?.status} ${t?.receivedBytes}/${t?.totalBytes} ${t?.errorMessage ?? ''} ${t?.localPath}');
          if (t == null || !t.status.isActive) break;
        }
      } catch (error, stack) {
        print('debug ERROR $error\n$stack');
      }
    });
  }

  // Test hooks for the Wi-Fi handoff:
  //   --send <file>              serve it and print the code + link
  //   --receive <code|url> <watch|save>
  final si = args.indexOf('--send');
  if (si >= 0 && si + 1 < args.length) {
    final path = args[si + 1];
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final offer = await PhoneHandoff.offer(File(path));
      // ignore: avoid_print
      print('debug send code=${offer?.code} url=${offer?.url} ips=${offer?.ips}');
    });
  }
  final ri = args.indexOf('--receive');
  if (ri >= 0 && ri + 1 < args.length) {
    final raw = args[ri + 1];
    final mode = ri + 2 < args.length ? args[ri + 2] : 'save';
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future<void>.delayed(const Duration(seconds: 2));
      // ignore_for_file: avoid_print
      final sw = Stopwatch()..start();
      final target = await PhoneHandoff.resolve(raw);
      print('debug resolve ${target?.videoUrl} in ${sw.elapsedMilliseconds}ms');
      if (target == null) return;
      if (mode == 'watch') {
        await appRouter.push('/player',
            extra: PlayerSession(title: target.title, platform: SocialPlatform.direct, networkUrl: target.videoUrl));
        return;
      }
      var last = -1;
      final file = await PhoneHandoff.download(target, onProgress: (r, t) {
        final pct = t > 0 ? r * 100 ~/ t : 0;
        if (pct ~/ 20 != last) {
          last = pct ~/ 20;
          print('debug progress $pct% $r/$t');
        }
      });
      print('debug saved ${file?.path} ${file?.lengthSync()}');
    });
  }

  // Desktop test hook: `SocialSave.exe --play <file>` opens the in-app player.
  final at = args.indexOf('--play');
  if (at >= 0 && at + 1 < args.length && File(args[at + 1]).existsSync()) {
    final path = args[at + 1];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // ignore: avoid_print
      print('debug --play $path');
      appRouter.push(
        '/player',
        extra: PlayerSession(
          title: path.split(Platform.pathSeparator).last,
          platform: SocialPlatform.direct,
          filePath: path,
        ),
      );
    });
  }
}
