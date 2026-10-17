import 'package:social_save/core/config/build_flags.dart';

/// The hosted SocialSave API (Android app and website only).
///
/// Every reference to the hosted address goes through here and sits behind
/// [kLocalEngine], so the desktop build compiles without it.
class HostedApi {
  const HostedApi._();

  /// Origin of the hosted API, or empty in the desktop build.
  static String get origin =>
      kLocalEngine ? '' : 'https://socialsave-api-p2tm.onrender.com';

  /// Host name shown to people on the website flow, or empty on desktop.
  static String get displayHost =>
      kLocalEngine ? '' : 'socialsave-api-p2tm.onrender.com';

  /// True when [hostOrUrl] points at the hosted API. Always false on desktop.
  static bool matches(String hostOrUrl) =>
      kLocalEngine ? false : hostOrUrl.toLowerCase().contains('onrender.com');
}
