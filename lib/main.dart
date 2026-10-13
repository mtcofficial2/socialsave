import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:social_save/core/theme/app_theme.dart';
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
import 'package:social_save/features/library/nearby_service.dart';
import 'package:social_save/features/library/bundle_transfer.dart';
import 'package:social_save/core/platform/desktop_support.dart';
import 'package:social_save/features/library/nearby_ui.dart';
import 'package:social_save/features/library/phone_handoff.dart';
import 'package:social_save/features/library/transfer_meter.dart';
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
  // Nearby test hooks (no UI, no database):
  //   --nearby-recv <name>         announce, auto-accept, print progress
  //   --nearby-send <name> <file>  wait for a device, send the file to it
  final nr = args.indexOf('--nearby-recv');
  if (nr >= 0 && nr + 1 < args.length) {
    NearbyService.onOffer = (o) async {
      print('debug offer from ${o.fromName}: ${o.fileName} ${o.size}');
      return true;
    };
    await NearbyService.start(testId: 'recv${args[nr + 1]}', testName: args[nr + 1]);
    print('debug nearby-recv started as ${NearbyService.name}');
    NearbyService.devices.addListener(() => print('debug sees ${NearbyService.devices.value.map((d) => '${d.name}@${d.host}:${d.port}').toList()}'));
    NearbyService.incoming.addListener(() {
      final v = NearbyService.incoming.value;
      if (v == null) return;
      if (!v.done) print('debug recv progress ${v.detail}');
      if (v.done) {
        print('debug received ${v.received}/${v.total} file=${v.file?.path} dir=${v.dir?.path} ${v.fileName} ${v.detail}');
        Future<void>.delayed(const Duration(seconds: 2), () => exit(v.file == null && v.dir == null ? 1 : 0));
      }
    });
    await Future<void>.delayed(const Duration(minutes: 5));
    exit(2);
  }
  // `--recycle-test <path>...`: send paths to the Recycle Bin (delete test).
  final rt = args.indexOf('--recycle-test');
  if (rt >= 0 && rt + 1 < args.length) {
    final gone = await DesktopSupport.recycle(args.sublist(rt + 1));
    print('debug recycled ${gone.length}/${args.length - rt - 1}');
    exit(0);
  }
  // `--nearby-send-dir <name> <folder-or-file>`: send a folder / file bundle.
  final nd = args.indexOf('--nearby-send-dir');
  if (nd >= 0 && nd + 2 < args.length) {
    await NearbyService.start(testId: 'send${args[nd + 1]}', testName: args[nd + 1]);
    final sw = Stopwatch()..start();
    while (NearbyService.devices.value.isEmpty && sw.elapsed.inSeconds < 20) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final list = NearbyService.devices.value;
    if (list.isEmpty) exit(1);
    final src = args[nd + 2];
    final bundle = FileSystemEntity.isDirectorySync(src)
        ? await SendBundle.fromFolder(Directory(src))
        : await SendBundle.fromFiles([File(src)]);
    print('debug bundle ${bundle?.summary} ${bundle?.total} bytes');
    final meter = TransferMeter();
    final err = await NearbyService.sendBundle(list.first, bundle!,
        onStatus: (s) => print('debug status $s'),
        onProgress: (s, t, i, r) {
          if (meter.update(s, t)) print('debug send progress ${meter.label}');
        });
    print('debug send ${meter.doneLabel}');
    print('debug nearby-send result=${err ?? 'ok'}');
    exit(err == null ? 0 : 1);
  }
  final ns = args.indexOf('--nearby-send');
  if (ns >= 0 && ns + 2 < args.length) {
    await NearbyService.start(testId: 'send${args[ns + 1]}', testName: args[ns + 1]);
    final sw = Stopwatch()..start();
    while (NearbyService.devices.value.isEmpty && sw.elapsed.inSeconds < 20) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final list = NearbyService.devices.value;
    print('debug found ${list.map((d) => '${d.name}(${d.kind})@${d.host}:${d.port}').toList()} after ${sw.elapsedMilliseconds}ms');
    if (list.isEmpty) exit(1);
    final meter = TransferMeter();
    final err = await NearbyService.sendTo(list.first, File(args[ns + 2]),
        onStatus: (s) => print('debug status $s'),
        onProgress: (s, t) {
          if (meter.update(s, t)) print('debug send progress ${meter.label}');
        });
    print('debug send ${meter.doneLabel}');
    print('debug nearby-send result=${err ?? 'ok'}');
    exit(err == null ? 0 : 1);
  }

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
  var settings = await settingsStore.load();
  // 1.0.14: dark theme with the SocialSave colors is the new default. Move
  // installs that were still on the old defaults (system + dynamic) once.
  if (prefs.getBool('ui_v14_defaults') != true) {
    if (settings.themeMode == ThemeMode.system && settings.useDynamicColor) {
      settings = settings.copyWith(themeMode: ThemeMode.dark, useDynamicColor: false);
      await settingsStore.save(settings);
    }
    await prefs.setBool('ui_v14_defaults', true);
  }
  // Screenshot hook: `--open /library` starts on that tab.
  final op = args.indexOf('--open');
  if (op >= 0 && op + 1 < args.length) debugInitialLocation = args[op + 1];
  final notifications = NotificationService();
  await notifications.init();

  // Load the theme fonts before the first frame so chips and segmented
  // buttons are measured with the real font (they don't re-measure later).
  AppTheme.dark(fontFamily: settings.fontFamily);
  AppTheme.light(fontFamily: settings.fontFamily);
  try {
    await GoogleFonts.pendingFonts().timeout(const Duration(seconds: 4));
  } catch (_) {}

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
  installNearbyUi();
  unawaited(NearbyService.start());

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
