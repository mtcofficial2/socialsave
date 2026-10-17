import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:social_save/core/config/build_flags.dart';

/// State of the bundled download engine, shown in Settings.
class EngineStatus {
  const EngineStatus({
    required this.state,
    this.message = '',
    this.ytdlp = '',
    this.hasFfmpeg = false,
    this.hasDeno = false,
    this.updating = false,
  });

  /// starting, ready, missing, failed, off
  final String state;
  final String message;
  final String ytdlp;
  final bool hasFfmpeg;
  final bool hasDeno;
  final bool updating;

  bool get ready => state == 'ready';

  EngineStatus copyWith({String? state, String? message, String? ytdlp, bool? hasFfmpeg, bool? hasDeno, bool? updating}) =>
      EngineStatus(
        state: state ?? this.state,
        message: message ?? this.message,
        ytdlp: ytdlp ?? this.ytdlp,
        hasFfmpeg: hasFfmpeg ?? this.hasFfmpeg,
        hasDeno: hasDeno ?? this.hasDeno,
        updating: updating ?? this.updating,
      );
}

/// Windows: analyze and download run on this PC.
///
/// The app ships `engine\` next to SocialSave.exe with the SocialSave engine
/// (the same API the phone app uses, built for Windows), yt-dlp, ffmpeg /
/// ffprobe and deno. The engine listens on 127.0.0.1 only and exits with the
/// app. yt-dlp is kept current in %LOCALAPPDATA%\SocialSave\engine, because
/// YouTube changes often break older versions.
class LocalEngine {
  LocalEngine._();

  static bool get enabled => kLocalEngine && !kIsWeb && Platform.isWindows;

  static final status = ValueNotifier<EngineStatus>(
    const EngineStatus(state: 'off'),
  );

  static int _port = 47390;
  static Process? _process;
  static Completer<bool> _ready = Completer<bool>();
  static int _restarts = 0;
  static bool _stopping = false;
  static String _ytdlpPath = '';

  static String get baseUrl => 'http://127.0.0.1:$_port';

  static String get _sep => Platform.pathSeparator;
  static String get appDir => File(Platform.resolvedExecutable).parent.path;
  static String get bundledDir => '$appDir${_sep}engine';
  static String get dataDir {
    final local = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    return '$local${_sep}SocialSave${_sep}engine';
  }

  static String get _engineExe => '$bundledDir${_sep}socialsave-engine.exe';
  static String get _logPath => '$dataDir${_sep}engine.log';

  /// Starts the engine once. The port is chosen before this returns, so the
  /// HTTP client can be created right away; requests wait for [waitReady].
  static Future<void> start() async {
    if (!enabled || _process != null) return;
    _stopping = false;
    try {
      Directory(dataDir).createSync(recursive: true);
    } catch (_) {}
    _port = await _freePort();
    await _spawn();
    unawaited(_dailyUpdate());
  }

  /// Waits until the engine answers /health (or fails to start).
  static Future<bool> waitReady({Duration timeout = const Duration(seconds: 45)}) async {
    if (!enabled) return true;
    if (status.value.ready) return true;
    try {
      return await _ready.future.timeout(timeout);
    } catch (_) {
      return false;
    }
  }

  static Future<int> _freePort() async {
    // Keep the current port when it is free, so URLs already handed out
    // (a download in the queue) still reach the restarted engine.
    try {
      final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, _port);
      await s.close();
      return _port;
    } catch (_) {}
    for (var p = 47390; p < 47400; p++) {
      try {
        final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, p);
        await s.close();
        return p;
      } catch (_) {}
    }
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = s.port;
    await s.close();
    return p;
  }

  static String _versionOf(String dir) {
    try {
      return File('$dir${_sep}yt-dlp.version').readAsStringSync().trim();
    } catch (_) {
      return '';
    }
  }

  /// The newer of the bundled yt-dlp and the one this app updated.
  static (String, String) _pickYtdlp() {
    final bundled = '$bundledDir${_sep}yt-dlp.exe';
    final updated = '$dataDir${_sep}yt-dlp.exe';
    final bv = _versionOf(bundledDir);
    final uv = _versionOf(dataDir);
    final hasUpdated = File(updated).existsSync() && uv.isNotEmpty;
    if (hasUpdated && (uv.compareTo(bv) > 0 || !File(bundled).existsSync())) {
      return (updated, uv);
    }
    return (bundled, bv);
  }

  static Future<void> _spawn() async {
    if (_ready.isCompleted) _ready = Completer<bool>();
    final exe = _engineExe;
    final (ytdlp, ytdlpVersion) = _pickYtdlp();
    _ytdlpPath = ytdlp;
    final ffmpeg = File('$bundledDir${_sep}ffmpeg.exe').existsSync();
    final deno = File('$bundledDir${_sep}deno.exe').existsSync();
    status.value = EngineStatus(
      state: 'starting',
      ytdlp: ytdlpVersion,
      hasFfmpeg: ffmpeg,
      hasDeno: deno,
    );
    if (!File(exe).existsSync() || !File(ytdlp).existsSync()) {
      status.value = status.value.copyWith(
        state: 'missing',
        message: 'The download engine is missing from $bundledDir. Reinstall SocialSave.',
      );
      if (!_ready.isCompleted) _ready.complete(false);
      return;
    }
    final secret = List.generate(32, (_) => Random.secure().nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final env = <String, String>{
      'PORT': '$_port',
      'BIND_ADDR': '127.0.0.1',
      'PUBLIC_BASE_URL': baseUrl,
      'LOCAL_ENGINE': '1',
      'EXIT_WITH_STDIN': '1',
      'ENVIRONMENT': 'desktop',
      'SECRET_KEY': secret,
      'ALLOW_RENDER_FILE_PROXY': 'true',
      'MAX_DOWNLOAD_BYTES': '${32 * 1024 * 1024 * 1024}',
      'DEFAULT_MAX_HEIGHT': '2160',
      'JOB_TTL_SECONDS': '3600',
      'TOKEN_TTL_SECONDS': '21600',
      'ANALYZE_RATE_LIMIT': '600',
      'DOWNLOAD_RATE_LIMIT': '600',
      'YTDLP_PATH': ytdlp,
      'YTDLP_NO_UPDATE': '1',
      if (ffmpeg) 'FFMPEG_LOCATION': bundledDir,
      if (deno) 'DENO_PATH': '$bundledDir${_sep}deno.exe',
    };
    IOSink? log;
    try {
      log = File(_logPath).openWrite();
      log.writeln('[${DateTime.now().toIso8601String()}] start port=$_port yt-dlp=$ytdlpVersion ($ytdlp)');
    } catch (_) {}
    try {
      final p = await Process.start(
        exe,
        const [],
        workingDirectory: dataDir,
        environment: env,
      );
      _process = p;
      p.stdout.listen((d) => log?.add(d), onError: (_) {});
      p.stderr.listen((d) => log?.add(d), onError: (_) {});
      unawaited(p.exitCode.then((code) async {
        try {
          log?.writeln('[${DateTime.now().toIso8601String()}] exit $code');
          await log?.flush();
          await log?.close();
        } catch (_) {}
        if (_process == p) _process = null;
        if (_stopping) return;
        status.value = status.value.copyWith(state: 'failed', message: 'The download engine stopped (code $code).');
        if (!_ready.isCompleted) _ready.complete(false);
        if (_restarts < 3) {
          _restarts++;
          await Future<void>.delayed(Duration(seconds: 2 * _restarts));
          _port = await _freePort();
          await _spawn();
        }
      }));
    } catch (e) {
      status.value = status.value.copyWith(state: 'failed', message: 'Could not start the download engine: $e');
      if (!_ready.isCompleted) _ready.complete(false);
      return;
    }
    unawaited(_pollHealth());
  }

  static Future<void> _pollHealth() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    final until = DateTime.now().add(const Duration(seconds: 40));
    try {
      while (DateTime.now().isBefore(until) && _process != null) {
        try {
          final req = await client.getUrl(Uri.parse('$baseUrl/health'));
          final res = await req.close().timeout(const Duration(seconds: 3));
          await res.drain<void>();
          if (res.statusCode == 200) {
            status.value = status.value.copyWith(state: 'ready', message: '');
            if (!_ready.isCompleted) _ready.complete(true);
            return;
          }
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (!_ready.isCompleted) {
        status.value = status.value.copyWith(state: 'failed', message: 'The download engine did not start.');
        _ready.complete(false);
      }
    } finally {
      client.close(force: true);
    }
  }

  /// Stops and starts the engine (after a yt-dlp update).
  static Future<void> restart() async {
    if (!enabled) return;
    _stopping = true;
    final p = _process;
    _process = null;
    p?.kill();
    try {
      await p?.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {}
    _stopping = false;
    _restarts = 0;
    _port = await _freePort();
    await _spawn();
  }

  static const _stampName = 'update-check.txt';

  static Future<void> _dailyUpdate() async {
    final stamp = File('$dataDir$_sep$_stampName');
    try {
      final last = DateTime.tryParse(stamp.readAsStringSync().trim());
      if (last != null && DateTime.now().difference(last) < const Duration(hours: 20)) return;
    } catch (_) {}
    // Let the app settle first; never compete with the first analyze.
    await Future<void>.delayed(const Duration(seconds: 20));
    final changed = await updateYtdlp();
    if (changed && !_busy()) await restart();
  }

  static bool _busy() => busyCheck?.call() ?? false;

  /// Set by the download manager: true while downloads are running, so an
  /// update restart never cuts one (the update then applies next launch).
  static bool Function()? busyCheck;

  /// Fetches the latest yt-dlp release into the data folder when it is newer.
  /// Returns true when a new yt-dlp was installed.
  static Future<bool> updateYtdlp({bool restartAfter = false}) async {
    if (!enabled || status.value.updating) return false;
    status.value = status.value.copyWith(updating: true);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = 'SocialSave-desktop';
    try {
      final latest = await _getJson(client, Uri.parse('https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest'));
      final tag = (latest['tag_name'] as String? ?? '').trim();
      try {
        File('$dataDir$_sep$_stampName').writeAsStringSync(DateTime.now().toIso8601String());
      } catch (_) {}
      final (_, current) = _pickYtdlp();
      if (tag.isEmpty || tag.compareTo(current) <= 0) return false;
      final base = 'https://github.com/yt-dlp/yt-dlp/releases/download/$tag';
      final sums = await _getText(client, Uri.parse('$base/SHA2-256SUMS'));
      final line = sums.split('\n').firstWhere(
            (l) => l.trim().endsWith(' yt-dlp.exe'),
            orElse: () => '',
          );
      final want = line.split(' ').first.trim().toLowerCase();
      if (want.length != 64) return false;
      final part = File('$dataDir${_sep}yt-dlp.exe.part');
      final req = await client.getUrl(Uri.parse('$base/yt-dlp.exe'));
      final res = await req.close();
      if (res.statusCode != 200) return false;
      final sink = part.openWrite();
      await res.pipe(sink);
      final got = sha256.convert(await part.readAsBytes()).toString();
      if (got != want) {
        await part.delete();
        return false;
      }
      final target = File('$dataDir${_sep}yt-dlp.exe');
      if (target.existsSync() && target.path == _ytdlpPath && _process != null) {
        // In use: swap after the engine stops.
        await restartWith(() async {
          await part.rename(target.path);
        });
      } else {
        await part.rename(target.path);
      }
      File('$dataDir${_sep}yt-dlp.version').writeAsStringSync(tag);
      status.value = status.value.copyWith(ytdlp: tag);
      if (restartAfter && !_busy()) await restart();
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
      status.value = status.value.copyWith(updating: false);
    }
  }

  /// Stops the engine, runs [swap], then starts it again.
  static Future<void> restartWith(Future<void> Function() swap) async {
    _stopping = true;
    final p = _process;
    _process = null;
    p?.kill();
    try {
      await p?.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {}
    try {
      await swap();
    } finally {
      _stopping = false;
      _restarts = 0;
      _port = await _freePort();
      await _spawn();
    }
  }

  static Future<Map<String, dynamic>> _getJson(HttpClient client, Uri uri) async {
    final text = await _getText(client, uri);
    return jsonDecode(text) as Map<String, dynamic>;
  }

  static Future<String> _getText(HttpClient client, Uri uri) async {
    final req = await client.getUrl(uri);
    final res = await req.close().timeout(const Duration(seconds: 30));
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: uri);
    return body;
  }
}
