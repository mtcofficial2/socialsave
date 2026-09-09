import 'dart:io';

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
    defaultValue: 2147483647, // 2 GB
  );

  static String get apiBaseUrl {
    if (_apiBaseUrlDefine.isNotEmpty) {
      return _stripTrailingSlash(_apiBaseUrlDefine);
    }
    return _stripTrailingSlash(_defaultBaseUrl());
  }

  static bool get hasApiKey => apiKey.isNotEmpty;

  static String _defaultBaseUrl() {
    // Android emulator maps host loopback to 10.0.2.2.
    if (Platform.isAndroid) {
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
