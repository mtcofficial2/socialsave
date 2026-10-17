import 'dart:async';
import 'package:social_save/core/engine/local_engine.dart';
import 'package:social_save/features/library/desktop_tray.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/core/engine/phone_engine.dart';
import 'package:social_save/core/config/build_flags.dart';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:social_save/core/platform/media_events.dart';
import 'package:flutter/material.dart';
import 'package:social_save/features/player/presentation/screens/in_app_player_screen.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:social_save/core/theme/app_theme.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/features/downloader/presentation/providers/download_manager.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/app.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/network/windows_dns_fallback.dart';
import 'package:social_save/core/notifications/notification_service.dart';
import 'package:social_save/core/storage/hive_init.dart';
import 'package:social_save/features/downloads/data/datasources/download_history_store.dart';
import 'package:social_save/features/library/nearby_service.dart';
import 'package:social_save/features/library/bundle_transfer.dart';
import 'package:social_save/core/platform/desktop_support.dart';
import 'package:social_save/core/platform/open_with.dart';
import 'package:social_save/features/library/nearby_ui.dart';
import 'package:social_save/features/library/phone_handoff.dart';
import 'package:social_save/features/library/hotspot_share.dart';
import 'package:social_save/features/library/share_session.dart';
import 'package:social_save/features/library/session_media_picker.dart';
import 'package:social_save/features/library/session_ui.dart';
import 'package:flutter/rendering.dart';
import 'dart:ui' as ui;
import 'package:social_save/features/library/transfer_meter.dart';
import 'package:social_save/features/library/presentation/library_screen.dart';
import 'package:social_save/features/library/vault_service.dart';
import 'package:social_save/features/settings/data/datasources/settings_store.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/routing/app_router.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Plat.isAndroid) {
    // 1.0.36: session / hotspot diagnostics also reach logcat in release
    // builds (tag SocialSaveSession), so pairing problems can be read back.
    final base = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) {
      base(m, wrapWidth: wrapWidth);
      if (m != null && m.startsWith('[')) {
        MediaEvents.channel.invokeMethod<void>('log', {'m': m}).then((_) {}, onError: (_) {});
      }
    };
  }
  if (kIsWeb) {
    await _runWeb();
    return;
  }
  // Before the database. A second Open with launch must still be listed,
  // even when another SocialSave already holds the downloads box.
  // Test copies (--test-data) leave the installed app's Open with entry alone.
  if (Plat.isWindows && !args.contains('--test-data')) {
    unawaited(registerWindowsVideoPlayer());
  }
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

  // Session test hooks (no UI, no database):
  //   --session-host <name> <reply-file>          accept one session, send reply-file back once
  //   --session-join <name> <ip:port> <file> [<second-file>]
  //       connect, send <file>, wait for the reply, stay idle 15 s and check
  //       the session is still alive, then send <second-file> in the same
  //       session (1.0.33: "a finished transfer never ends the session").
  //   --session-quiet <s>   (either side) pretend the link is quiet sooner
  final sq = args.indexOf('--session-quiet');
  if (sq >= 0 && sq + 1 < args.length) {
    ShareSession.quietAfter = Duration(seconds: int.parse(args[sq + 1]));
  }
  final sh = args.indexOf('--session-host');
  if (sh >= 0 && sh + 2 < args.length) {
    ShareSession.persist = false;
    await NearbyService.start(testId: 'host${args[sh + 1]}', testName: args[sh + 1]);
    ShareSession.install();
    ShareSession.onRequest = (name, kind) async {
      print('debug session request from $name ($kind) -> accept');
      return true;
    };
    var replied = false;
    ShareSession.onOpened = () => print('debug session opened with ${ShareSession.peer.value?.name} '
        '${ShareSession.peer.value?.host}:${ShareSession.peer.value?.port}');
    var lastLog = '';
    ShareSession.revision.addListener(() {
      final log = [
        for (final it in ShareSession.items)
          'debug item ${it.outgoing ? 'out' : 'in'} ${it.name} ${it.state.name} ${it.state == SessionItemState.done || it.state == SessionItemState.failed ? '${it.done}/${it.size} ${it.detail}' : ''}',
      ].join('\n');
      if (log != lastLog) {
        lastLog = log;
        print(log);
      }
      final got = ShareSession.items.where((i) => !i.outgoing && i.state == SessionItemState.done).length;
      if (got >= 1 && !replied && args[sh + 2] != '-') {
        replied = true;
        print('debug host sends reply ${args[sh + 2]}');
        ShareSession.enqueue([File(args[sh + 2])]);
      }
    });
    ShareSession.state.addListener(() {
      print('debug session state ${ShareSession.state.value} ${ShareSession.endReason}');
      if (ShareSession.state.value == 'closed') {
        final got = ShareSession.items.where((i) => !i.outgoing && i.state == SessionItemState.done).length;
        print('debug host received $got file(s) in one session');
        Future<void>.delayed(const Duration(seconds: 1), () => exit(0));
      }
    });
    print('debug session-host ready port=${NearbyService.inboxBoundPort}');
    await Future<void>.delayed(const Duration(minutes: 10));
    exit(2);
  }
  final sj = args.indexOf('--session-join');
  if (sj >= 0 && sj + 3 < args.length) {
    ShareSession.persist = false;
    await NearbyService.start(testId: 'join${args[sj + 1]}', testName: args[sj + 1]);
    ShareSession.install();
    final hp = args[sj + 2].split(':');
    final err = await ShareSession.connect(host: hp[0], port: int.parse(hp[1]));
    print('debug session connect ${err ?? 'ok'} peer=${ShareSession.peer.value?.name}');
    if (err != null) exit(1);
    final files = [for (final f in args.sublist(sj + 3)) if (!f.startsWith('--') && File(f).existsSync()) File(f)];
    final first = files.first;
    final second = files.length > 1 ? files[1] : null;
    ShareSession.state.addListener(() => print('debug session state ${ShareSession.state.value} ${ShareSession.endReason}'));
    var lastLog = '';
    ShareSession.revision.addListener(() {
      final log = [
        for (final it in ShareSession.items)
          'debug item ${it.outgoing ? 'out' : 'in'} ${it.name} ${it.state.name} ${it.state == SessionItemState.done || it.state == SessionItemState.failed ? '${it.done}/${it.size} ${it.detail}' : ''}',
      ].join('\n');
      if (log != lastLog) {
        lastLog = log;
        print(log);
      }
    });
    Future<void> waitFor(bool Function() ok, String what, Duration limit) async {
      final end = DateTime.now().add(limit);
      while (!ok()) {
        if (DateTime.now().isAfter(end)) {
          print('debug session-join timeout waiting for $what');
          exit(1);
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }

    int sent() => ShareSession.items.where((i) => i.outgoing && i.state == SessionItemState.done).length;
    int got() => ShareSession.items.where((i) => !i.outgoing && i.state == SessionItemState.done).length;
    ShareSession.enqueue([first]);
    await waitFor(() => sent() >= 1 && got() >= 1, 'first send + reply', const Duration(minutes: 4));
    print('debug phase1 ok: sent 1, received reply');
    // 1.0.33 regression: the session must survive the end of a transfer.
    for (var i = 0; i < 15; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (!ShareSession.active) {
        print('debug FAIL session ended ${i + 1}s after the transfer: ${ShareSession.endReason}');
        exit(1);
      }
    }
    print('debug alive-after-transfer ok state=${ShareSession.state.value}');
    if (second != null) {
      ShareSession.enqueue([second]);
      await waitFor(() => sent() >= 2, 'second send', const Duration(minutes: 4));
      print('debug second-send ok (same session)');
    }
    print('debug all transfers done; disconnecting');
    await ShareSession.disconnect();
    print('debug session-join result=ok ${ShareSession.endReason}');
    exit(0);
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
  // Desktop: analyze and download run on this PC (bundled engine).
  await LocalEngine.start();

  if (args.contains('--test-data')) {
    InAppPlayerScreen.noPersist = true;
    HiveInit.debugDir = '${Directory.systemTemp.path}${Platform.pathSeparator}ss_testdata';
  }
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
  if (args.contains('--open-vault')) debugOpenVault = true;
  if (args.contains('--open-menu')) debugOpenMenu = true;
  if (args.contains('--dock-first')) debugDockFirst = true;
  final notifications = NotificationService();
  await notifications.init();

  // Load the theme fonts before the first frame so chips and segmented
  // buttons are measured with the real font (they don't re-measure later).
  AppTheme.dark(fontFamily: settings.fontFamily);
  AppTheme.light(fontFamily: settings.fontFamily);
  try {
    await GoogleFonts.pendingFonts().timeout(const Duration(seconds: 4));
  } catch (_) {}

  // "Download on this phone (no server)": keep yt-dlp current (daily, only
  // while the switch is on).
  if (Plat.isAndroid && !kLocalEngine) {
    unawaited(Future<void>.delayed(const Duration(seconds: 20), PhoneEngine.updateIfDue));
  }

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
  if (args.contains('--session-ui-test') || args.contains('--picker-test') || args.contains('--pair-test')) {
    ShareSession.persist = false;
  }
  unawaited(DesktopTray.install());
  installNearbyUi();
  if (args.contains('--picker-test')) unawaited(_pickerTest());
  final su = args.indexOf('--session-ui-test');
  if (su >= 0 && su + 2 < args.length) unawaited(_sessionUiTest(args[su + 1], args[su + 2]));
  final pt = args.indexOf('--pair-test');
  if (pt >= 0 && pt + 2 < args.length) {
    unawaited(_pairTest(args[pt + 1], args[pt + 2], pt + 3 < args.length ? args[pt + 3] : null));
  }
  unawaited(NearbyService.start());
  listenForOpenedVideos();
  listenForQuickActions();

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
        print('debug formats ${media.formats.map((f) => '${f.id}:${f.quality}:${f.format}:${f.height ?? '-'}').toList()}');
        // `--format <id|height|audio|audio-mp3>` picks one (default: first).
        final fi = args.indexOf('--format');
        final want = fi >= 0 && fi + 1 < args.length ? args[fi + 1] : null;
        final format = want == null
            ? media.formats.first
            : media.formats.firstWhere(
                (f) => f.id == want || '${f.height}' == want,
                orElse: () => media.formats.first,
              );
        print('debug picked ${format.id} ${format.quality} ${format.format}');
        final task = await c.read(downloadManagerProvider.notifier).enqueue(
              media: media,
              format: format,
            );
        print('debug enqueued ${task.id} -> ${task.localPath}');
        for (var i = 0; i < 600; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          final t = c.read(downloadManagerProvider).byId(task.id);
          print('debug status ${t?.status} ${t?.receivedBytes}/${t?.totalBytes} ${t?.errorMessage ?? ''} ${t?.localPath} pct=${((t?.progress ?? 0) * 100).toStringAsFixed(1)} phase=${t?.phase} bps=${t?.bytesPerSecond.round()}');
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

  // `--key-log`: print every key the player handles (keyboard tests).
  if (args.contains('--key-log')) InAppPlayerScreen.keyLog = true;
  if (args.contains('--seek-bench')) InAppPlayerScreen.seekBench = true;
  if (args.contains('--fs-ui-test')) InAppPlayerScreen.fsUiTest = true;

  // Open with, or `SocialSave.exe --play <file>`, opens that video.
  final opened = openedVideoArgument(args);
  if (opened != null && File(opened).existsSync()) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(playOpenedVideo(opened));
    });
  }
}

/// Browser build: the same app and screens, without the parts a browser
/// cannot do (files on disk, nearby share, the Vault, native players).
/// Downloads are kept in this browser's storage (IndexedDB via Hive).
Future<void> _runWeb() async {
  MediaKit.ensureInitialized();
  await Hive.initFlutter();
  final box = await Hive.openBox<String>(AppConstants.downloadsBoxName);
  final prefs = await SharedPreferences.getInstance();
  final settingsStore = SharedPreferencesSettingsStore(prefs);
  var settings = await settingsStore.load();
  if (prefs.getBool('ui_v14_defaults') != true) {
    if (settings.themeMode == ThemeMode.system && settings.useDynamicColor) {
      settings = settings.copyWith(themeMode: ThemeMode.dark, useDynamicColor: false);
      await settingsStore.save(settings);
    }
    await prefs.setBool('ui_v14_defaults', true);
  }
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
        notificationServiceProvider.overrideWithValue(NotificationService()),
        vaultServiceProvider.overrideWithValue(VaultService(prefs)),
      ],
      child: const SocialSaveApp(),
    ),
  );
}


/// `--picker-test`: opens the Connected screen with a pretend peer, lets the
/// media grid load, saves a screenshot to %TEMP%\ss_picker.png and exits.
Future<void> _pickerTest() async {
  await Future<void>.delayed(const Duration(seconds: 5));
  debugPickerAutoSelect = 3;
  ShareSession.peer.value = SessionPeer(
    id: 'picker-test',
    name: 'Test phone',
    kind: 'phone',
    host: '127.0.0.1',
    port: 9,
    link: 'wifi',
  );
  unawaited(openSessionScreen());
  await Future<void>.delayed(const Duration(seconds: 20));
  try {
    final view = RendererBinding.instance.renderViews.first;
    // ignore: invalid_use_of_protected_member
    final layer = view.layer! as OffsetLayer;
    final image = await layer.toImage(Offset.zero & view.flutterView.physicalSize);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}ss_picker.png');
    await file.writeAsBytes(data!.buffer.asUint8List());
    print('debug picker shot ${file.path}');
  } catch (e) {
    print('debug picker shot failed $e');
  }
  exit(0);
}


Future<void> _shot(String name) async {
  try {
    final view = RendererBinding.instance.renderViews.first;
    // ignore: invalid_use_of_protected_member
    final layer = view.layer! as OffsetLayer;
    final image = await layer.toImage(Offset.zero & view.flutterView.physicalSize);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}$name.png');
    await file.writeAsBytes(data!.buffer.asUint8List());
    print('debug shot ${file.path}');
  } catch (e) {
    print('debug shot failed $e');
  }
}

/// `--session-ui-test <ip:port> <file>`: windowed check that leaving the
/// Connected screen keeps the session: connect, open the screen, go back,
/// wait, send a file from outside the screen, screenshot the pill, then
/// disconnect. Prints `debug ui-test result=ok` on success.
Future<void> _sessionUiTest(String hostPort, String file) async {
  ShareSession.persist = false;
  await Future<void>.delayed(const Duration(seconds: 6));
  final hp = hostPort.split(':');
  final err = await ShareSession.connect(host: hp[0], port: int.parse(hp[1]));
  print('debug ui-test connect ${err ?? 'ok'}');
  if (err != null) exit(1);
  await Future<void>.delayed(const Duration(seconds: 4));
  print('debug ui-test screen open=${ShareSession.screenOpen}');
  await _shot('ss_session_screen');
  final nav = appRouter.routerDelegate.navigatorKey.currentState;
  nav?.pop();
  await Future<void>.delayed(const Duration(seconds: 2));
  print('debug ui-test left screen open=${ShareSession.screenOpen} active=${ShareSession.active}');
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(seconds: 1));
    if (!ShareSession.active) {
      print('debug ui-test FAIL session ended after leaving the screen: ${ShareSession.endReason}');
      exit(1);
    }
  }
  print('debug ui-test still connected 20s after leaving the screen');
  ShareSession.enqueue([File(file)]);
  final end = DateTime.now().add(const Duration(minutes: 3));
  while (!ShareSession.items.any((i) => i.outgoing && i.state == SessionItemState.done)) {
    if (DateTime.now().isAfter(end) || ShareSession.items.any((i) => i.state == SessionItemState.failed)) {
      print('debug ui-test FAIL send from outside the screen');
      exit(1);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  print('debug ui-test sent from outside the screen ok; active=${ShareSession.active}');
  await Future<void>.delayed(const Duration(seconds: 3));
  await _shot('ss_session_pill');
  await ShareSession.disconnect();
  print('debug ui-test result=ok');
  await Future<void>.delayed(const Duration(seconds: 1));
  exit(0);
}


/// True when a dialog / bottom sheet is on top of the root navigator.
bool _popupOnTop() {
  final nav = appRouter.routerDelegate.navigatorKey.currentState;
  var popup = false;
  nav?.popUntil((r) {
    popup = r is PopupRoute;
    return true;
  });
  return popup;
}

Future<bool> _waitFor(bool Function() ok, Duration max) async {
  final end = DateTime.now().add(max);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return true;
}

String _pairState() => 'popupOnTop=${_popupOnTop()} pairingUi=${ShareSession.pairingUi.length} '
    'screenOpen=${ShareSession.screenOpen} active=${ShareSession.active}';

/// `--pair-test host <file>` / `--pair-test join <file>` (run both): checks
/// that every pairing dialog closes by itself the moment the session opens
/// (Xender-style), that both land on the Connected screen, that the file
/// picked before connecting is the first transfer, and that files go both
/// ways. The host opens the Send code dialog with <file>; the joiner opens
/// the Connect picker and connects to the host's inbox port. Prints
/// `debug pair-test <role> result=ok`.
Future<void> _pairTest(String role, String file, [String? file2]) async {
  ShareSession.persist = false;
  // The two copies run with their own TEMP (separate test data), so the
  // port file can be put in a shared place.
  final portFile = File(Platform.environment['SS_PAIR_PORT_FILE'] ??
      '${Directory.systemTemp.path}${Platform.pathSeparator}ss_pair_port.txt');
  final name = file.split(RegExp(r'[\\/]')).last;
  Never fail(String why) {
    print('debug pair-test $role FAIL $why');
    exit(1);
  }

  await Future<void>.delayed(const Duration(seconds: 6));
  final nav = appRouter.routerDelegate.navigatorKey.currentState!;
  if (role == 'host') {
    ShareSession.onRequest = (n, k) async => true; // auto-accept in the test
    unawaited(showSendToPhone(nav.context, File(file), name));
    await Future<void>.delayed(const Duration(seconds: 3));
    print('debug pair-test host before ${_pairState()}');
    await _shot('ss_pair_host_before');
    if (!_popupOnTop()) fail('code dialog did not open');
    await portFile.writeAsString('${NearbyService.inboxBoundPort}');
    if (!await _waitFor(() => ShareSession.active, const Duration(minutes: 2))) fail('no session');
    final at = DateTime.now();
    final closed = await _waitFor(() => !_popupOnTop() && ShareSession.pairingUi.isEmpty && ShareSession.screenOpen,
        const Duration(seconds: 5));
    print('debug pair-test host connected; dialog closed=$closed after ${DateTime.now().difference(at).inMilliseconds} ms; ${_pairState()}');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await _shot('ss_pair_host_after');
    if (!closed) fail('dialog still open after connecting');
    final first = ShareSession.items.isEmpty ? null : ShareSession.items.reduce((a, b) => a.key < b.key ? a : b);
    print('debug pair-test host first item=${first?.name} outgoing=${first?.outgoing}');
    if (first == null || !first.outgoing || first.name != name) fail('picked file is not the first transfer');
    if (!await _waitFor(() => first.state == SessionItemState.done, const Duration(minutes: 3))) fail('first file not sent');
    print('debug pair-test host first file sent');
    if (!await _waitFor(() => ShareSession.items.any((i) => !i.outgoing && i.state == SessionItemState.done),
        const Duration(minutes: 3))) {
      fail('nothing received back');
    }
    final back = ShareSession.items.firstWhere((i) => !i.outgoing && i.state == SessionItemState.done);
    print('debug pair-test host received back ${back.name} ${back.size} bytes -> ${back.file?.path}');
    await Future<void>.delayed(const Duration(seconds: 1));
    await _shot('ss_pair_host_transfers');
    await _waitFor(() => !ShareSession.active, const Duration(seconds: 60));
    print('debug pair-test host result=ok (session ended: ${ShareSession.endReason})');
    try {
      await portFile.delete();
    } catch (_) {}
    await Future<void>.delayed(const Duration(seconds: 1));
    exit(0);
  }
  if (role == 'quick-host') {
    // One-tap Hotspot share (no file), a joiner scans the QR (pair token).
    ShareSession.onRequest = (n, k) async => true;
    unawaited(showHotspotQuickShare(nav.context));
    if (!await _waitFor(() => ShareSession.pairLink != null || !_popupOnTop(), const Duration(seconds: 90))) {
      fail('hotspot did not start');
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    final link = ShareSession.pairLink;
    print('debug pair-test quick-host link=$link band=${HotspotShare.lastInfo?.bandLabel} note=${HotspotShare.lastInfo?.bandNote}');
    await _shot('ss_quick_host_qr');
    if (link == null) fail('no QR (hotspot failed to start?)');
    final q = Uri.parse(link);
    // sp|sid|code|ssid|password: a real phone joins by hand and types the code.
    await portFile.writeAsString('${q.queryParameters['sp']}|${q.queryParameters['sid']}|${PhoneHandoff.current?.code}|'
        '${HotspotShare.lastInfo?.ssid}|${HotspotShare.lastInfo?.password}');
    if (!await _waitFor(() => ShareSession.active, const Duration(minutes: 2))) fail('no session');
    final at = DateTime.now();
    final closed = await _waitFor(() => !_popupOnTop() && ShareSession.pairingUi.isEmpty && ShareSession.screenOpen,
        const Duration(seconds: 5));
    print('debug pair-test quick-host connected via ${ShareSession.peer.value?.link}; dialog closed=$closed after '
        '${DateTime.now().difference(at).inMilliseconds} ms; ${_pairState()}');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await _shot('ss_quick_host_after');
    if (!closed) fail('hotspot dialog still open after connecting');
    if (!await _waitFor(() => ShareSession.items.any((i) => !i.outgoing && i.state == SessionItemState.done),
        const Duration(minutes: 3))) {
      fail('nothing received');
    }
    ShareSession.enqueue([File(file)]);
    if (!await _waitFor(() => ShareSession.items.any((i) => i.outgoing && i.state == SessionItemState.done),
        const Duration(minutes: 3))) {
      fail('send failed');
    }
    print('debug pair-test quick-host sent and received; hotspot running=${await HotspotShare.isRunning()}');
    await Future<void>.delayed(const Duration(seconds: 1));
    await _shot('ss_quick_host_transfers');
    await _waitFor(() => !ShareSession.active, const Duration(seconds: 60));
    await Future<void>.delayed(const Duration(seconds: 4));
    print('debug pair-test quick-host session ended (${ShareSession.endReason}); hotspot running after Disconnect=${await HotspotShare.isRunning()}');
    print('debug pair-test quick-host result=ok');
    exit(0);
  }
  if (role == 'legacy-host') {
    // An older SocialSave (simulated by the test script) only downloads by
    // code: the code dialog must still close into a (legacy) session.
    ShareSession.onRequest = (n, k) async => true;
    unawaited(showSendToPhone(nav.context, File(file), name));
    await Future<void>.delayed(const Duration(seconds: 3));
    await _shot('ss_legacy_host_before');
    final offer = PhoneHandoff.current;
    if (offer == null) fail('no offer');
    await portFile.writeAsString('${offer.port}|${offer.code}');
    if (!await _waitFor(() => ShareSession.active, const Duration(minutes: 2))) fail('no session');
    final at = DateTime.now();
    final closed = await _waitFor(() => !_popupOnTop() && ShareSession.pairingUi.isEmpty && ShareSession.screenOpen,
        const Duration(seconds: 5));
    final peer = ShareSession.peer.value!;
    print('debug pair-test legacy-host session legacy=${peer.legacy} name=${peer.name} host=${peer.host}; dialog closed=$closed after '
        '${DateTime.now().difference(at).inMilliseconds} ms; ${_pairState()}');
    if (!closed || !peer.legacy) fail('did not land in a legacy session');
    if (!await _waitFor(() => ShareSession.items.any((i) => i.outgoing && i.state == SessionItemState.done),
        const Duration(minutes: 3))) {
      fail('first file not fetched');
    }
    await Future<void>.delayed(const Duration(seconds: 1));
    await _shot('ss_legacy_host_after');
    print('debug pair-test legacy-host first file fetched; queueing ${file2 ?? '-'}');
    if (file2 != null) {
      ShareSession.enqueue([File(file2)]);
      await Future<void>.delayed(const Duration(seconds: 2));
      final it = ShareSession.items.last;
      print('debug pair-test legacy-host queued: ${it.name} ${it.state.name} "${it.detail}"');
      await _shot('ss_legacy_host_queued');
      if (!await _waitFor(() => it.state == SessionItemState.done, const Duration(minutes: 3))) fail('second file not fetched');
      print('debug pair-test legacy-host second file fetched by receiving again');
    }
    unawaited(sendAppToPeer(nav.context));
    if (!await _waitFor(() => PhoneHandoff.apkUrl() != null, const Duration(seconds: 20))) fail('no apk to send');
    await Future<void>.delayed(const Duration(seconds: 2));
    print('debug pair-test legacy-host apk url ${PhoneHandoff.apkUrl()} (${PhoneHandoff.apkFile?.path})');
    await File('${portFile.path}.apk').writeAsString(PhoneHandoff.apkUrl()!);
    await _shot('ss_legacy_send_app');
    await Future<void>.delayed(const Duration(seconds: 15));
    nav.pop();
    await Future<void>.delayed(const Duration(seconds: 1));
    await _shot('ss_legacy_host_end');
    await ShareSession.disconnect();
    print('debug pair-test legacy-host result=ok');
    await Future<void>.delayed(const Duration(seconds: 1));
    exit(0);
  }
  if (role == 'code-join') {
    // 1.0.36: this PC types the other device's code (Receive), the way a
    // user does after joining its hotspot by hand: it must land on the
    // Connected screen (full session, or limited with a clear status).
    if (!await _waitFor(() => portFile.existsSync() && portFile.readAsStringSync().trim().isNotEmpty, const Duration(minutes: 5))) {
      fail('no code');
    }
    final code = portFile.readAsStringSync().trim();
    final at = DateTime.now();
    unawaited(receiveHandoff(nav.context, code));
    if (!await _waitFor(() => ShareSession.active, const Duration(minutes: 2))) fail('no session after typing the code');
    final landed = await _waitFor(() => !_popupOnTop() && ShareSession.screenOpen, const Duration(seconds: 8));
    final peer = ShareSession.peer.value!;
    print('debug pair-test code-join landed=$landed limited=${peer.limited} legacy=${peer.legacy} with ${peer.name} '
        '${peer.host}:${peer.port} via ${peer.link} after ${DateTime.now().difference(at).inMilliseconds} ms; ${_pairState()}');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await _shot('ss_code_join_after');
    if (!landed) fail('did not land on the Connected screen');
    if (!await _waitFor(() => ShareSession.items.any((i) => !i.outgoing && i.state == SessionItemState.done),
        const Duration(minutes: 4))) {
      fail('nothing received');
    }
    final got = ShareSession.items.firstWhere((i) => !i.outgoing && i.state == SessionItemState.done);
    print('debug pair-test code-join received ${got.name} ${got.size} bytes -> ${got.file?.path}');
    ShareSession.enqueue([File(file)]);
    if (!await _waitFor(() => ShareSession.items.any((i) => i.outgoing && i.state != SessionItemState.queued && !i.active),
        const Duration(minutes: 3))) {
      fail('send did not finish');
    }
    final sent = ShareSession.items.firstWhere((i) => i.outgoing);
    print('debug pair-test code-join sent ${sent.name}: ${sent.state.name} ${sent.detail}');
    await Future<void>.delayed(const Duration(seconds: 1));
    await _shot('ss_code_join_transfers');
    await _waitFor(() => !ShareSession.active, const Duration(seconds: 90));
    print('debug pair-test code-join result=${sent.state == SessionItemState.done ? 'ok' : 'FAIL'} (ended: ${ShareSession.endReason})');
    exit(sent.state == SessionItemState.done ? 0 : 1);
  }
  // Joiner.
  unawaited(showConnectPicker(nav.context));
  await Future<void>.delayed(const Duration(seconds: 2));
  print('debug pair-test join before ${_pairState()}');
  await _shot('ss_pair_join_before');
  if (!_popupOnTop()) fail('connect picker did not open');
  if (!await _waitFor(() => portFile.existsSync() && portFile.readAsStringSync().trim().isNotEmpty, const Duration(minutes: 2))) {
    fail('no host port');
  }
  final spec = portFile.readAsStringSync().trim().split('|');
  final port = int.parse(spec[0]);
  final pair = spec.length > 1 ? spec[1] : null;
  final ip = Platform.environment['SS_PAIR_IP'] ?? '127.0.0.1';
  // Same as tapping the device in the picker / scanning the hotspot QR
  // (the picker stays open meanwhile).
  final err = await ShareSession.connect(host: ip, port: port, pair: pair, link: pair != null ? 'hotspot' : 'wifi');
  print('debug pair-test join connect ${err ?? 'ok'} to $ip:$port');
  if (err != null) fail('connect: $err');
  final at = DateTime.now();
  final closed = await _waitFor(() => !_popupOnTop() && ShareSession.pairingUi.isEmpty && ShareSession.screenOpen,
      const Duration(seconds: 5));
  print('debug pair-test join picker closed=$closed after ${DateTime.now().difference(at).inMilliseconds} ms; ${_pairState()}');
  await Future<void>.delayed(const Duration(milliseconds: 700));
  await _shot('ss_pair_join_after');
  if (!closed) fail('picker still open after connecting');
  if (pair != null) {
    // Quick share: nothing was picked on the host; this side sends first.
    ShareSession.enqueue([File(file)]);
  }
  if (!await _waitFor(() => ShareSession.items.any((i) => !i.outgoing && i.state == SessionItemState.done),
      const Duration(minutes: 3))) {
    fail("host's file never arrived");
  }
  final first = ShareSession.items.reduce((a, b) => a.key < b.key ? a : b);
  print('debug pair-test join first item=${first.name} outgoing=${first.outgoing} ${first.size} bytes -> ${first.file?.path}');
  print('debug pair-test join popupOnTop after receiving=${_popupOnTop()} (no Watch/Save dialog expected)');
  if (_popupOnTop()) fail('a receive dialog popped up in session mode');
  if (pair == null) ShareSession.enqueue([File(file)]);
  if (!await _waitFor(() => ShareSession.items.any((i) => i.outgoing && i.state == SessionItemState.done),
      const Duration(minutes: 3))) {
    fail('send back failed');
  }
  print('debug pair-test join sent back $name; active=${ShareSession.active}');
  await Future<void>.delayed(const Duration(seconds: 2));
  await _shot('ss_pair_join_transfers');
  await ShareSession.disconnect();
  print('debug pair-test join result=ok');
  await Future<void>.delayed(const Duration(seconds: 1));
  exit(0);
}
