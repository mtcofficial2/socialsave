import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/library/pc_hotspot.dart';

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

  /// Joining a hotspot from the app (Android phones).
  static bool get supported => !kIsWeb && Plat.isAndroid;

  /// Opening a hotspot to send from: Android phones and Windows PCs
  /// (Windows Mobile hotspot).
  static bool get hostSupported => !kIsWeb && (Plat.isAndroid || Plat.isWindows);
  static bool get _pc => !kIsWeb && Plat.isWindows;

  static void _wire() {
    if (_wired) return;
    _wired = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'lost') joinedLinkUp.value = false;
      if (call.method == 'available') joinedLinkUp.value = true;
      if (call.method == 'stopped') hostRunning.value = false;
      event.value = '${call.method}@${DateTime.now().millisecondsSinceEpoch}';
    });
  }

  /// Last hotspot this phone opened (host) and joined (receiver); used to
  /// bring a connected session's link back after a drop.
  static HotspotInfo? lastInfo;
  static HotspotJoin? lastJoin;

  /// Host: is our hotspot up? Receiver: is the joined link up?
  static final ValueNotifier<bool> hostRunning = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> joinedLinkUp = ValueNotifier<bool>(false);

  /// Is the hotspot reservation still alive (asks Android)?
  static Future<bool> isRunning() async {
    if (_pc) return PcHotspot.isRunning();
    if (!supported) return false;
    try {
      return (await status())['hotspotRunning'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Opens the hotspot again with the same name and password (Android 13+
  /// lets us choose them), so the other phone can rejoin by itself.
  static Future<HotspotInfo?> reopen() async {
    final last = lastInfo;
    if (last == null || !supported) return null;
    try {
      final info = await start(reuseSsid: last.custom ? last.ssid : null, reusePassword: last.custom ? last.password : null);
      return info;
    } catch (e) {
      debugPrint('[hotspot] reopen failed: $e');
      return null;
    }
  }

  /// Joins the last hotspot again (after the link dropped).
  static Future<bool> rejoin() async {
    final j = lastJoin;
    if (j == null || !supported) return false;
    try {
      await join(j.ssid, j.password);
      return true;
    } catch (e) {
      debugPrint('[hotspot] rejoin failed: $e');
      return false;
    }
  }

  static Future<Map<String, dynamic>> status() async {
    _wire();
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>('status');
    return (raw ?? const {}).map((k, v) => MapEntry('$k', v));
  }

  /// Asks for the needed permission and checks Wi-Fi / Location.
  /// Returns a user-facing message when something blocks Fast share.
  static Future<String?> prepare({required bool sending}) async {
    if (_pc && sending) return PcHotspot.prepare();
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

  static const _bandKey = 'hotspot_band';

  /// 'auto' (prefer 5 GHz), '5' or '2.4'. Remembered across launches.
  static final ValueNotifier<String> band = ValueNotifier<String>('auto');
  static bool _bandLoaded = false;

  static Future<String> loadBand() async {
    if (!_bandLoaded) {
      _bandLoaded = true;
      try {
        final v = (await SharedPreferences.getInstance()).getString(_bandKey);
        if (v == 'auto' || v == '5' || v == '2.4') band.value = v!;
      } catch (_) {}
    }
    return band.value;
  }

  static Future<void> setBand(String v) async {
    band.value = v;
    _bandLoaded = true;
    try {
      await (await SharedPreferences.getInstance()).setString(_bandKey, v);
    } catch (_) {}
  }

  /// Starts the hotspot. Returns ssid / password / ip.
  static Future<HotspotInfo> start({String? reuseSsid, String? reusePassword}) async {
    if (_pc) return _startPc(reuseSsid, reusePassword);
    _wire();
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('start', {
        'band': await loadBand(),
        if (reuseSsid != null) 'ssid': reuseSsid,
        if (reusePassword != null) 'password': reusePassword,
      });
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
      final info = HotspotInfo(
        ssid: ssid,
        password: (m['password'] as String?) ?? '',
        ip: ip,
        custom: m['custom'] == true,
        band: (m['band'] as num?)?.toInt(),
        bandNote: (m['bandNote'] as String?) ?? '',
      );
      lastInfo = info;
      hostRunning.value = true;
      return info;
    } on PlatformException catch (e) {
      throw HotspotError(e.message ?? 'The hotspot could not start.');
    }
  }

  /// Windows Mobile hotspot (see [PcHotspot]).
  static Future<HotspotInfo> _startPc(String? reuseSsid, String? reusePassword) async {
    final want = await loadBand();
    final r = await PcHotspot.start(band: want, ssid: reuseSsid, password: reusePassword);
    if (r['ok'] != true) {
      throw HotspotError(PcHotspot.blockMessage(r) ?? '${r['error'] ?? 'Mobile hotspot did not start.'}');
    }
    final block = PcHotspot.blockMessage(r);
    if (block != null) throw HotspotError(block);
    final ip = await PcHotspot.address();
    final band = switch ('${r['band']}') {
      'FiveGigahertz' => 2,
      'TwoPointFourGigahertz' => 1,
      'SixGigahertz' => 4,
      'Auto' => 3,
      _ => null,
    };
    final notes = <String>[
      if ('${r['note'] ?? ''}'.isNotEmpty) '${r['note']}',
      if (r['reused'] == true) 'Using your Mobile hotspot that was already on (it stays on afterwards).',
      if (want == '5' && band != 2 && '${r['note'] ?? ''}'.isEmpty && r['has5'] != true) 'This PC\'s Wi-Fi can\'t host on 5 GHz.',
    ];
    final info = HotspotInfo(
      ssid: '${r['ssid']}',
      password: '${r['password'] ?? ''}',
      ip: ip,
      custom: r['custom'] == true,
      band: band,
      bandNote: notes.join(' '),
    );
    if (info.ssid.isEmpty || info.ssid == 'null') throw const HotspotError('Mobile hotspot started but Windows did not share its name.');
    lastInfo = info;
    hostRunning.value = true;
    return info;
  }

  static Future<void> stop() async {
    if (_pc) {
      if (!hostRunning.value && lastInfo == null) return;
      hostRunning.value = false;
      await PcHotspot.stop();
      return;
    }
    if (!supported) return;
    hostRunning.value = false;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  /// Joins the sender's hotspot and routes this app's traffic over it.
  static Future<void> join(String ssid, String password) async {
    _wire();
    try {
      await _channel.invokeMethod<Object?>('join', {'ssid': ssid, 'password': password});
      lastJoin = HotspotJoin(ssid: ssid, password: password);
      joinedLinkUp.value = true;
    } on PlatformException catch (e) {
      throw HotspotError(e.message ?? 'Could not join $ssid.');
    }
  }

  static Future<void> leave() async {
    if (!supported) return;
    joinedLinkUp.value = false;
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
  const HotspotInfo({
    required this.ssid,
    required this.password,
    this.ip,
    this.custom = false,
    this.band,
    this.bandNote = '',
  });

  /// SoftAp band mask of the running hotspot: 1 = 2.4 GHz, 2 = 5 GHz,
  /// 3 = either (phone picks), 4 = 6 GHz; null when the phone doesn't say.
  final int? band;

  /// Why the band differs from the choice (or empty).
  final String bandNote;

  String get bandLabel => switch (band) {
        2 => 'Hotspot on 5 GHz',
        1 => 'Hotspot on 2.4 GHz',
        3 => 'Hotspot on 2.4 or 5 GHz (phone picks)',
        4 => 'Hotspot on 6 GHz',
        _ => 'Hotspot band: phone default',
      };

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


/// Auto / 5 GHz / 2.4 GHz choice for Fast share (dialog and Settings).
class HotspotBandPicker extends StatefulWidget {
  const HotspotBandPicker({super.key, this.onChanged, this.enabled = true});
  final ValueChanged<String>? onChanged;
  final bool enabled;

  @override
  State<HotspotBandPicker> createState() => _HotspotBandPickerState();
}

class _HotspotBandPickerState extends State<HotspotBandPicker> {
  @override
  void initState() {
    super.initState();
    HotspotShare.loadBand().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: HotspotShare.band,
      builder: (context, v, _) => SegmentedButton<String>(
        key: const ValueKey('hotspot-band'),
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: 'auto', label: Text('Auto'), tooltip: 'Prefer 5 GHz, fall back to 2.4 GHz'),
          ButtonSegment(value: '5', label: Text('5 GHz'), tooltip: 'Fastest'),
          ButtonSegment(value: '2.4', label: Text('2.4 GHz'), tooltip: 'Works with every phone and PC'),
        ],
        selected: {v},
        onSelectionChanged: widget.enabled
            ? (s) async {
                await HotspotShare.setBand(s.first);
                widget.onChanged?.call(s.first);
              }
            : null,
      ),
    );
  }
}

/// Settings row for the Fast share band.
class HotspotBandTile extends StatelessWidget {
  const HotspotBandTile({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wifi_tethering_rounded, color: scheme.onSurfaceVariant),
              const SizedBox(width: 16),
              const Expanded(
                child: Text('Fast share hotspot band', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: Text(
              Plat.isWindows
                  ? '5 GHz is fastest if this PC\'s Wi-Fi and the phone support it. 2.4 GHz works everywhere. '
                      'Windows may stay on the band your Wi-Fi is using.'
                  : '5 GHz is fastest (both phones must support it). 2.4 GHz works everywhere. '
                      'Android 13+ only; older phones use their default.',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 8),
          const Padding(padding: EdgeInsets.only(left: 40), child: HotspotBandPicker()),
        ],
      ),
    );
  }
}
