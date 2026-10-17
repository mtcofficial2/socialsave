import 'package:social_save/core/platform/plat.dart';

import 'package:flutter/foundation.dart';
import 'package:social_save/core/config/build_flags.dart';
import 'package:social_save/core/config/hosted_api.dart';
import 'package:social_save/core/engine/local_engine.dart';

/// Runtime configuration. Secrets never belong in source control.
///
/// Supply values with `--dart-define` or `--dart-define-from-file`.
/// Example:
/// `flutter run --dart-define=API_BASE_URL=https://api.example.com --dart-define=API_KEY=`
class EnvConfig {
  const EnvConfig._();

  static const String _apiBaseUrlDefine = String.fromEnvironment(
    'API_BASE_URL',
  );

  /// Optional public client token. Real provider credentials stay on the server.
  static const String apiKey = String.fromEnvironment('API_KEY');

  static const bool enableLogging = bool.fromEnvironment(
    'ENABLE_LOGGING',
    defaultValue: true,
  );

  static const int analyzeTimeoutSeconds = int.fromEnvironment(
    'ANALYZE_TIMEOUT_SECONDS',
    defaultValue: 90,
  );

  static const int downloadTimeoutSeconds = int.fromEnvironment(
    'DOWNLOAD_TIMEOUT_SECONDS',
    defaultValue: 600,
  );

  static const int maxDownloadBytes = int.fromEnvironment(
    'MAX_DOWNLOAD_BYTES',
    defaultValue: 2147483648, // 2 GiB
  );

  /// Live API used by Android and web release builds. A debug build still
  /// uses the local computer unless API_BASE_URL is passed at compile time.
  /// The desktop build has no hosted API: it talks to its bundled engine.
  static String get productionApiBaseUrl => HostedApi.origin;

  static String get apiBaseUrl {
    if (kLocalEngine) {
      // Windows: the bundled engine on this PC (yt-dlp + ffmpeg + deno).
      return LocalEngine.baseUrl;
    }
    // Web build served by the API itself: talk to the same origin.
    if (kIsWeb && HostedApi.matches(Uri.base.host)) {
      return Uri.base.origin;
    }
    if (_apiBaseUrlDefine.isNotEmpty) {
      return _stripTrailingSlash(_apiBaseUrlDefine);
    }
    return _stripTrailingSlash(_defaultBaseUrl());
  }

  static bool get hasApiKey => apiKey.isNotEmpty;

  static String _defaultBaseUrl() {
    if (!kDebugMode) {
      return productionApiBaseUrl;
    }
    // Android emulator maps the computer's loopback to 10.0.2.2.
    if (Plat.isAndroid) {
      return 'http://10.0.2.2:8000';
    }
    return 'http://127.0.0.1:8000';
  }

  static String _stripTrailingSlash(String value) {
    if (value.endsWith('/')) {
      return value.substring(0, value.length - 1);
    }
    return value;
  }
}
