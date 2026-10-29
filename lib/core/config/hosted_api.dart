import 'package:social_save/core/config/build_flags.dart';

/// The hosted SocialSave API (Android app and website only).
///
/// Pass the address at build time:
/// `--dart-define=API_BASE_URL=https://your-api.example`.
/// It stays empty when that define is omitted, including the desktop build.
/// This file does not name a deployed server.
class HostedApi {
  const HostedApi._();

  static const String _defined = String.fromEnvironment('API_BASE_URL');

  /// Origin of the hosted API, or empty when no address was compiled in.
  static String get origin {
    if (kLocalEngine) return '';
    return _strip(_defined);
  }

  /// Host name shown on the website flow, or empty when none was compiled in.
  static String get displayHost {
    final value = origin;
    if (value.isEmpty) return '';
    return Uri.tryParse(value)?.host ?? '';
  }

  /// True when [hostOrUrl] is the API host compiled in with API_BASE_URL.
  static bool matches(String hostOrUrl) {
    final host = displayHost.toLowerCase();
    if (kLocalEngine || host.isEmpty) return false;
    final lower = hostOrUrl.trim().toLowerCase();
    if (lower == host) return true;
    final parsed = Uri.tryParse(lower.contains('://') ? lower : 'https://$lower');
    return parsed != null && parsed.host == host;
  }

  static String _strip(String value) {
    final trimmed = value.trim();
    if (trimmed.endsWith('/')) {
      return trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }
}
