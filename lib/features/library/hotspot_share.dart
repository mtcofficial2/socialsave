import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:social_save/core/platform/plat.dart';

/// Xender-style "Fast share": the sending phone opens its own local-only
/// Wi-Fi hotspot and the receiving phone joins it, so the file goes phone
/// to phone at full Wi-Fi speed with no router and no internet.
///
/// The QR stays a normal handoff link with the hotspot added as query
/// parameters, e.g. `http://192.168.43.1:47321/v/CODE/name.mp4?hs=SSID&hp=PASS`,
/// so older receivers still understand the rest of it.
class HotspotShare {
  HotspotShare._();

  static const MethodChannel _channel = MethodChannel('socialsave/hotspot');
  static bool _wired = false;

  /// Fires when the sender's hotspot stops on its own (or the receiver
  /// loses the link).
  static final ValueNotifier<String?> event = ValueNotifier<String?>(null);

  static bool get supported => !kIsWeb && Plat.isAndroid;

  static void _wire() {
    if (_wired) return;
    _wired = true;
    _channel.setMethodCallHandler((call) async {
      event.value = '${call.method}@${DateTime.now().millisecondsSinceEpoch}';
    });
  }

  static Future<Map<String, dynamic>> status() async {
    _wire();
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>('status');
    return (raw ?? const {}).map((k, v) => MapEntry('$k', v));
  }

  /// Asks for the needed permission and checks Wi-Fi / Location.
  /// Returns a user-facing message when something blocks Fast share.
  static Future<String?> prepare({required bool sending}) async {
    if (!supported) return 'Fast share works between Android phones.';
    final s = await status();
    final sdk = (s['sdk'] as int?) ?? 0;
    if (sending && sdk < 26) return 'Fast share needs Android 8 or newer on the sending phone.';
    if (sdk >= 33) {
      final st = await Permission.nearbyWifiDevices.request();
      if (!st.isGranted) {
        return st.isPermanentlyDenied
            ? 'Allow "Nearby devices" for SocialSave in Settings › Apps to use Fast share.'
            : 'Fast share needs the "Nearby devices" permission.';
      }
    } else {
      final st = await Permission.locationWhenInUse.request();
      if (!st.isGranted) {
        return st.isPermanentlyDenied
            ? 'Allow Location for SocialSave in Settings › Apps to use Fast share (Android needs it for Wi-Fi hotspots).'
            : 'Fast share needs the Location permission on this Android version.';
      }
      if (s['locationOn'] != true) {
        return 'Turn on Location (quick settings), then try Fast share again.';
      }
    }
    if (!sending && s['wifiOn'] != true && sdk >= 29) {
      return 'Turn on Wi-Fi, then try again.';
    }
    return null;
  }

  /// Starts the hotspot. Returns ssid / password / ip.
  static Future<HotspotInfo> start() async {
    _wire();
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('start');
      final m = (raw ?? const {}).map((k, v) => MapEntry('$k', v));
      var ip = m['ip'] as String?;
      // The interface can take a moment to get its address.
      for (var i = 0; ip == null && i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        ip = await _channel.invokeMethod<String>('apAddress');
      }
      final ssid = m['ssid'] as String?;
      if (ssid == null || ssid.isEmpty) {
        throw const HotspotError('The hotspot started but the phone did not share its name.');
      }
      return HotspotInfo(ssid: ssid, password: (m['password'] as String?) ?? '', ip: ip, custom: m['custom'] == true);
    } on PlatformException catch (e) {
      throw HotspotError(e.message ?? 'The hotspot could not start.');
    }
  }

  static Future<void> stop() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  /// Joins the sender's hotspot and routes this app's traffic over it.
  static Future<void> join(String ssid, String password) async {
    _wire();
    try {
      await _channel.invokeMethod<Object?>('join', {'ssid': ssid, 'password': password});
    } on PlatformException catch (e) {
      throw HotspotError(e.message ?? 'Could not join $ssid.');
    }
  }

  static Future<void> leave() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('leave');
    } catch (_) {}
  }

  /// Hotspot details carried in a scanned link, or null.
  static HotspotJoin? parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != 'http') return null;
    final ssid = uri.queryParameters['hs'];
    if (ssid == null || ssid.isEmpty) return null;
    return HotspotJoin(ssid: ssid, password: uri.queryParameters['hp'] ?? '');
  }

  /// Adds the hotspot to a handoff link.
  static String link(String baseUrl, HotspotInfo info) {
    final q = 'hs=${Uri.encodeQueryComponent(info.ssid)}&hp=${Uri.encodeQueryComponent(info.password)}';
    return '$baseUrl${baseUrl.contains('?') ? '&' : '?'}$q';
  }
}

class HotspotInfo {
  const HotspotInfo({required this.ssid, required this.password, this.ip, this.custom = false});

  /// True when the phone accepted SocialSave's short 8-digit password.
  final bool custom;
  final String ssid;
  final String password;
  final String? ip;
}

class HotspotJoin {
  const HotspotJoin({required this.ssid, required this.password});
  final String ssid;
  final String password;
}

class HotspotError implements Exception {
  const HotspotError(this.message);
  final String message;
  @override
  String toString() => message;
}
