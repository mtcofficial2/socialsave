import 'dart:async';
import 'package:social_save/core/platform/plat.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:social_save/core/platform/player_identity.dart';
import 'package:social_save/features/library/nearby_service.dart';
import 'package:social_save/features/library/share_session.dart';

/// USB cable mode (Windows): finds phones plugged in with USB debugging on,
/// tunnels the phone's Nearby inbox over adb (`adb forward`) and gives the
/// phone a way back to this PC (`adb reverse`), so both apps list each other
/// as "<name> (USB)" and transfers run over the cable instead of Wi-Fi.
class UsbLink {
  UsbLink._();

  static const int reversePort = 47326;
  static const String offHint = 'Turn on USB debugging or USB tethering for cable transfers';

  /// Short status line for the UI; empty when a cable link is working.
  static final ValueNotifier<String> hint = ValueNotifier(Plat.isAndroid ? offHint : '');

  static bool _started = false;
  static bool _tick = false;
  static String? _adb;
  static final Map<String, int> _forwards = {};
  static final Map<String, String> _models = {};

  /// Phones already offered a session for this plug-in (cleared on unplug),
  /// so a Decline or Disconnect isn't asked again every scan.
  static final Set<String> _sessionTried = {};

  /// 1.0.46: called once per plug-in with the phone's name (quick action).
  static void Function(String name)? onPlugged;

  static void start() {
    if (_started || !Plat.isWindows) return;
    _started = true;
    unawaited(_scan());
    Timer.periodic(const Duration(seconds: 3), (_) => unawaited(_scan()));
  }

  static String? _findAdb() {
    final candidates = <String>[
      p.join(p.dirname(Platform.resolvedExecutable), 'adb', 'adb.exe'),
      p.join(p.dirname(Platform.resolvedExecutable), 'adb.exe'),
      for (final v in ['ANDROID_HOME', 'ANDROID_SDK_ROOT'])
        if ((Platform.environment[v] ?? '').isNotEmpty)
          p.join(Platform.environment[v]!, 'platform-tools', 'adb.exe'),
      if ((Platform.environment['LOCALAPPDATA'] ?? '').isNotEmpty)
        p.join(Platform.environment['LOCALAPPDATA']!, 'Android', 'Sdk', 'platform-tools', 'adb.exe'),
      for (final dir in (Platform.environment['PATH'] ?? '').split(';'))
        if (dir.trim().isNotEmpty) p.join(dir.trim(), 'adb.exe'),
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  static Future<ProcessResult?> _run(List<String> args) async {
    final adb = _adb;
    if (adb == null) return null;
    try {
      return await Process.run(adb, args, runInShell: false).timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    }
  }

  static Future<void> _scan() async {
    if (_tick) return;
    _tick = true;
    try {
      _adb ??= _findAdb();
      if (_adb == null) {
        hint.value = offHint;
        return;
      }
      final r = await _run(['devices']);
      if (r == null || r.exitCode != 0) {
        hint.value = offHint;
        return;
      }
      final ready = <String>[];
      var unauthorized = false;
      for (final line in '${r.stdout}'.split('\n').skip(1)) {
        final cols = line.trim().split(RegExp(r'\s+'));
        if (cols.length < 2) continue;
        if (cols[1] == 'device') ready.add(cols[0]);
        if (cols[1] == 'unauthorized') unauthorized = true;
      }
      _forwards.removeWhere((serial, _) => !ready.contains(serial));
      _sessionTried.removeWhere((serial) => !ready.contains(serial));
      var linked = 0;
      for (final serial in ready) {
        if (await _link(serial)) linked++;
      }
      if (linked > 0) {
        hint.value = '';
      } else if (unauthorized) {
        hint.value = 'Tap "Allow USB debugging" on the phone for cable transfers';
      } else if (ready.isNotEmpty) {
        hint.value = 'Phone found on USB — open SocialSave on it for cable transfers';
      } else {
        hint.value = offHint;
      }
    } catch (error) {
      debugPrint('usb scan failed: $error');
    } finally {
      _tick = false;
    }
  }

  /// Tunnels one phone; true when its SocialSave answered over the cable.
  static Future<bool> _link(String serial) async {
    var port = _forwards[serial];
    if (port == null) {
      final r = await _run(['-s', serial, 'forward', 'tcp:0', 'tcp:${NearbyService.inboxPort}']);
      port = int.tryParse('${r?.stdout ?? ''}'.trim());
      if (port == null) return false;
      _forwards[serial] = port;
      await _run(['-s', serial, 'reverse', 'tcp:$reversePort', 'tcp:${NearbyService.inboxBoundPort}']);
      if (!_models.containsKey(serial)) {
        final m = await _run(['-s', serial, 'shell', 'getprop', 'ro.product.model']);
        _models[serial] = '${m?.stdout ?? ''}'.trim();
      }
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      // Tell the phone how to reach us (also refreshes our entry on its side).
      final req = await client.postUrl(Uri.http('127.0.0.1:$port', '/usbpeer'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'id': NearbyService.id,
        'name': NearbyService.name,
        'kind': NearbyService.kind,
        'player': thisPlayerName,
        'port': reversePort,
      }));
      final res = await req.close().timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) {
        // Older phone app without /usbpeer: fall back to /hello.
        await res.drain<void>();
        return await _hello(client, serial, port);
      }
      final j = jsonDecode(await utf8.decoder.bind(res).join()) as Map<String, dynamic>;
      _add(serial, port, j);
      return true;
    } catch (_) {
      // Tunnel went stale (app restarted / cable replugged): rebuild next time.
      _forwards.remove(serial);
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> _hello(HttpClient client, String serial, int port) async {
    final req = await client.getUrl(Uri.http('127.0.0.1:$port', '/hello'));
    final res = await req.close().timeout(const Duration(seconds: 3));
    if (res.statusCode != 200) return false;
    _add(serial, port, jsonDecode(await utf8.decoder.bind(res).join()) as Map<String, dynamic>);
    return true;
  }

  static void _add(String serial, int port, Map<String, dynamic> j) {
    final model = _models[serial] ?? '';
    final id = '${j['id'] ?? ''}';
    NearbyService.addUsbRoute(
      id: id,
      name: model.isNotEmpty ? model : '${j['name'] ?? 'Phone'}',
      kind: '${j['kind'] ?? 'phone'}',
      port: port,
    );
    // 1.0.45: a working cable link goes straight into the shared session
    // (the same Connected screen and transport as the hotspot share).
    if (id.isNotEmpty && id != NearbyService.id && _sessionTried.add(serial)) {
      onPlugged?.call(model.isNotEmpty ? model : '${j['name'] ?? 'Phone'}');
      unawaited(_openSession(id, port));
    }
  }

  static Future<void> _openSession(String id, int port) async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (ShareSession.active || ShareSession.closedRecently(id)) return;
    if (Platform.environment['SOCIALSAVE_NO_USB_SESSION'] == '1') return;
    final err = await ShareSession.openOverCable(id: id, host: '127.0.0.1', port: port, link: 'usb');
    debugPrint('usb session: ${err ?? 'connected'}');
  }
}
