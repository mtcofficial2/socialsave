import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/core/utils/platform_detector.dart';
import 'package:social_save/shared/models/download_ticket.dart';
import 'package:social_save/shared/models/media_format.dart';
import 'package:social_save/shared/models/media_info.dart';

/// Marks an error that came from the on-phone engine, so the UI can offer
/// "Try with server" (never done automatically while the switch is on).
class PhoneEngineFailure {
  const PhoneEngineFailure();
}

/// Android "Download on this phone (no server)": yt-dlp, Python, ffmpeg and
/// QuickJS run on the phone (youtubedl-android, as in Seal) through the
/// `socialsave/phone_engine` channel. Off by default; when off, nothing here runs.
class PhoneEngine {
  PhoneEngine._();

  static const _channel = MethodChannel('socialsave/phone_engine');
  static const _enabledKey = 'phone_engine.enabled.v1';
  static const _updatedKey = 'phone_engine.updated.v1';
  static const jobPrefix = 'phone:';

  /// The Settings switch. Loaded lazily from preferences.
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);
  static bool _loaded = false;

  static Future<bool> isEnabled() async {
    if (!Plat.isAndroid) return false;
    if (!_loaded) {
      final prefs = await SharedPreferences.getInstance();
      enabled.value = prefs.getBool(_enabledKey) ?? false;
      _loaded = true;
    }
    return enabled.value;
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);
    enabled.value = value;
    _loaded = true;
    if (value) unawaited(warm());
  }

  /// Links the user chose "Try with server" for: their next analyze and
  /// save go to the server once, even with the switch on.
  static final Set<String> serverFor = <String>{};

  static void useServerFor(String url) => serverFor.add(url.trim());

  static bool isEngineMessage(String? message) =>
      message != null && message.startsWith('On-phone engine:');

  /// YouTube's "confirm you're not a bot" (the server is blocked the same way,
  /// so the answer is signing in on the phone, not the server).
  static bool isBotCheck(String? message) =>
      message != null && message.contains("prove it isn't a bot");

  /// The message without the internal "On-phone engine:" tag.
  static String display(String message) => message.replaceFirst('On-phone engine: ', '');

  /// True once the WebView login left YouTube cookies on the phone.
  static final ValueNotifier<bool> youTubeSignedIn = ValueNotifier<bool>(false);

  static Future<bool> refreshYouTubeSignIn() async {
    try {
      youTubeSignedIn.value = await _channel.invokeMethod<bool>('ytSignedIn') ?? false;
    } catch (_) {}
    return youTubeSignedIn.value;
  }

  /// Opens the Google sign-in page; cookies stay in app-private storage.
  static Future<void> signInYouTube() async {
    try {
      await _channel.invokeMethod<bool>('ytSignIn');
    } catch (_) {}
  }

  static Future<void> signOutYouTube() async {
    try {
      await _channel.invokeMethod<bool>('ytSignOut');
    } catch (_) {}
    youTubeSignedIn.value = false;
  }

  static bool isEngineError(Object? error) =>
      error is AppException && error.cause is PhoneEngineFailure;

  static AppException _error(Object error) {
    var message = error is PlatformException ? (error.message ?? error.code) : '$error';
    message = message.trim();
    if (message.isEmpty) message = 'The on-phone engine stopped unexpectedly.';
    return AppException(
      code: AppErrorCode.serverError,
      message: 'On-phone engine: $message',
      cause: const PhoneEngineFailure(),
    );
  }

  /// {supported, ready, version}
  static Future<Map<String, dynamic>> status() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('status');
      return Map<String, dynamic>.from(raw ?? const {});
    } catch (_) {
      return const {'supported': false, 'ready': false};
    }
  }

  /// First use: unpacks Python and ffmpeg (a few seconds).
  static Future<Map<String, dynamic>> prepare() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('prepare');
      return Map<String, dynamic>.from(raw ?? const {});
    } catch (e) {
      throw _error(e);
    }
  }

  /// Unpacks the engine and loads Python in the background so the first
  /// paste doesn't wait for it. Safe to call often; does nothing when off.
  static Future<void> warm() async {
    if (!await isEnabled()) return;
    try {
      await _channel.invokeMethod<bool>('warm');
    } catch (_) {}
  }

  /// yt-dlp self-update (stable channel). Returns {status, version}.
  static Future<Map<String, dynamic>> update() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('update');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_updatedKey, DateTime.now().millisecondsSinceEpoch);
      return Map<String, dynamic>.from(raw ?? const {});
    } catch (e) {
      throw _error(e);
    }
  }

  /// At most once a day, in the background, while the switch is on.
  static Future<void> updateIfDue() async {
    if (!await isEnabled()) return;
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_updatedKey) ?? 0;
    if (DateTime.now().millisecondsSinceEpoch - last < const Duration(hours: 24).inMilliseconds) {
      return;
    }
    try {
      await update();
    } catch (_) {
      // Offline or GitHub limits: try again next launch.
    }
  }

  static Future<MediaInfo> analyze(String url) async {
    String raw;
    try {
      raw = await _channel.invokeMethod<String>('info', {'url': url}) ?? '';
    } catch (e) {
      throw _error(e);
    }
    final start = raw.indexOf('{');
    if (start < 0) throw _error('No video details were found for this link.');
    final decoded = jsonDecode(raw.substring(start));
    if (decoded is! Map) throw _error('No video details were found for this link.');
    return parseInfo(Map<String, dynamic>.from(decoded), url);
  }

  static Future<DownloadTicket> start({required String url, required String formatId}) async {
    final id = 'j${DateTime.now().microsecondsSinceEpoch}';
    try {
      await _channel.invokeMethod<bool>('start', {'id': id, 'url': url, 'formatId': formatId});
    } catch (e) {
      throw _error(e);
    }
    return DownloadTicket(
      downloadUrl: '',
      jobId: '$jobPrefix$id',
      state: DownloadJobState.processing,
    );
  }

  static String _id(String jobId) => jobId.substring(jobPrefix.length);

  static Future<DownloadJobStatus> job(String jobId) async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>('job', {'id': _id(jobId)});
    if (raw == null) {
      throw _error('This save was interrupted (the app was closed). Start it again.');
    }
    final m = Map<String, dynamic>.from(raw);
    final state = switch (m['state']) {
      'ready' => DownloadJobState.ready,
      'failed' || 'cancelled' => DownloadJobState.failed,
      _ => DownloadJobState.processing,
    };
    if (state == DownloadJobState.failed) {
      throw _error(m['state'] == 'cancelled'
          ? 'Cancelled.'
          : (m['error'] as String? ?? 'The download failed on this phone.'));
    }
    final path = m['path'] as String?;
    return DownloadJobStatus(
      id: jobId,
      state: state,
      downloadUrl: path == null ? null : Uri.file(path).toString(),
      progress: (m['progress'] as num?)?.toDouble(),
      downloadedBytes: (m['downloaded_bytes'] as num?)?.toInt(),
      totalBytes: (m['total_bytes'] as num?)?.toInt(),
      speed: (m['speed'] as num?)?.toDouble(),
      phase: m['phase'] as String?,
    );
  }

  static Future<void> cancel(String jobId) async {
    try {
      await _channel.invokeMethod<bool>('cancel', {'id': _id(jobId)});
    } catch (_) {}
  }

  static Future<void> cleanup(String jobId) async {
    try {
      await _channel.invokeMethod<bool>('cleanup', {'id': _id(jobId)});
    } catch (_) {}
  }

  // ---- yt-dlp JSON -> MediaInfo (same ids as the server's formats.go) ----

  static const _steps = [360, 480, 720, 1080, 1440, 2160];

  static bool _hasV(Map f) => (f['vcodec'] ?? 'none') != 'none' && f['vcodec'] != null;
  static bool _hasA(Map f) => (f['acodec'] ?? 'none') != 'none' && f['acodec'] != null;
  static int? _size(Map f) =>
      MediaFormat.parseInt(f['filesize']) ?? MediaFormat.parseInt(f['filesize_approx']);
  static double _tbr(Map f) => (f['tbr'] as num?)?.toDouble() ?? 0;

  @visibleForTesting
  static MediaInfo parseInfo(Map<String, dynamic> json, String url) {
    var info = json;
    if (info['_type'] == 'playlist' && info['entries'] is List && (info['entries'] as List).isNotEmpty) {
      info = Map<String, dynamic>.from((info['entries'] as List).first as Map);
    }
    final all = (info['formats'] is List ? info['formats'] as List : const [])
        .whereType<Map>()
        .toList();
    if (all.isEmpty) all.add(info);
    int? bestAudio;
    var anyAudio = _hasA(info);
    for (final f in all) {
      if (_hasA(f)) anyAudio = true;
      if (_hasA(f) && !_hasV(f)) {
        final s = _size(f);
        if (s != null && (bestAudio == null || s > bestAudio)) bestAudio = s;
      }
    }
    int? withAudio(Map f) {
      final s = _size(f);
      if (s == null) return null;
      return _hasA(f) || bestAudio == null ? s : s + bestAudio;
    }

    final buckets = <int, Map>{};
    for (final f in all) {
      final h = MediaFormat.parseInt(f['height']);
      if (!_hasV(f) || h == null || h <= 0) continue;
      final bucket = _steps.firstWhere((s) => h <= s, orElse: () => 2160);
      final cur = buckets[bucket];
      if (cur == null || _tbr(f) > _tbr(cur)) buckets[bucket] = f;
    }
    final width = MediaFormat.parseInt(info['width']);
    final height = MediaFormat.parseInt(info['height']);
    final top = buckets[1080] ??
        _steps.reversed.map((s) => buckets[s]).firstWhere((f) => f != null, orElse: () => null);
    final originalSize = withAudio(top ?? info);
    final formats = <MediaFormat>[
      MediaFormat(id: 'original', quality: 'original', format: 'mp4', filesize: originalSize,
          width: width, height: height),
      for (final s in _steps.reversed)
        if (buckets[s] != null)
          MediaFormat(
            id: '${s}p',
            quality: '${s}p',
            format: 'mp4',
            filesize: withAudio(buckets[s]!),
            width: MediaFormat.parseInt(buckets[s]!['width']),
            height: MediaFormat.parseInt(buckets[s]!['height']),
            hasAudio: _hasA(buckets[s]!) || bestAudio != null || anyAudio,
          ),
      MediaFormat(id: 'auto', quality: 'auto', format: 'mp4', filesize: originalSize,
          width: width, height: height),
      if (anyAudio) ...[
        // The phone engine extracts to M4A (-x) and encodes MP3 with ffmpeg.
        MediaFormat(id: 'audio', quality: 'audio', format: 'm4a', filesize: bestAudio,
            hasVideo: false),
        MediaFormat(id: 'audio-mp3', quality: 'audio', format: 'mp3', filesize: bestAudio,
            hasVideo: false),
      ],
    ];
    final title = (info['title'] as String?)?.trim();
    return MediaInfo(
      sourceUrl: (info['webpage_url'] as String?) ?? url,
      platform: const PlatformDetector().detect(url),
      title: title == null || title.isEmpty ? 'Untitled video' : title,
      thumbnailUrl: info['thumbnail'] as String?,
      author: (info['uploader'] ?? info['channel'] ?? info['creator']) as String?,
      durationSeconds: MediaFormat.parseInt(info['duration']),
      formats: formats,
      canDownload: true,
    );
  }
}
