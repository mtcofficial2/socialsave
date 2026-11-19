import 'dart:async';
import 'package:social_save/core/platform/plat.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:social_save/features/library/phone_control.dart';

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

  /// Plain-English logs from phones that answered over the cable.
  static final ValueNotifier<List<PluggedPhoneLog>> deviceLogs = ValueNotifier(const []);

  static final Map<String, PluggedPhoneLog> _logs = {};
  static DateTime _logsAt = DateTime.fromMillisecondsSinceEpoch(0);

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

  /// Phones that currently have a cable tunnel.
  static List<({String serial, String name})> phones() {
    return [
      for (final serial in _forwards.keys)
        (serial: serial, name: (_models[serial] ?? '').trim().isEmpty ? 'Phone' : _models[serial]!.trim()),
    ];
  }

  /// [named] is false when this phone's app has no app list yet.
  static Future<({List<PhoneControlApp> apps, bool named})> phoneApps(String serial) async {
    final port = _forwards[serial];
    if (port == null) return (apps: const <PhoneControlApp>[], named: false);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.getUrl(Uri.http('127.0.0.1:$port', '/phoneapps'));
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return (apps: const <PhoneControlApp>[], named: false);
      }
      final body = jsonDecode(await utf8.decoder.bind(res).join());
      return (apps: phoneControlApps(body), named: true);
    } catch (_) {
      return (apps: const <PhoneControlApp>[], named: false);
    } finally {
      client.close(force: true);
    }
  }

  static Future<Uint8List?> phoneShot(String serial) async {
    final adb = _adb ?? _findAdb();
    _adb ??= adb;
    if (adb == null || !_forwards.containsKey(serial)) return null;
    try {
      final proc = await Process.start(adb, ['-s', serial, 'exec-out', 'screencap', '-p'], runInShell: false);
      final builder = BytesBuilder(copy: false);
      unawaited(proc.stderr.drain<void>());
      await proc.stdout.forEach(builder.add);
      final code = await proc.exitCode.timeout(const Duration(seconds: 12));
      if (code != 0) return null;
      final bytes = builder.takeBytes();
      return phoneControlShot(bytes) ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _wake(String serial) async {
    final r = await _run(['-s', serial, 'shell', 'input', 'keyevent', '224']);
    return r != null && r.exitCode == 0;
  }

  /// Opens a launcher app on the phone. The package must be a normal package name.
  static Future<bool> openPhoneApp(String serial, String packageName) async {
    if (!phoneControlPackage(packageName) || !_forwards.containsKey(serial)) return false;
    await _wake(serial);
    final r = await _run(['-s', serial, 'shell', 'monkey', '-p', packageName, '-c', 'android.intent.category.LAUNCHER', '1']);
    return r != null && r.exitCode == 0;
  }

  static Future<bool> phoneKey(String serial, String name) async {
    const keys = {'back': '4', 'home': '3', 'recents': '187'};
    final code = keys[name];
    if (code == null || !_forwards.containsKey(serial)) return false;
    await _wake(serial);
    final r = await _run(['-s', serial, 'shell', 'input', 'keyevent', code]);
    return r != null && r.exitCode == 0;
  }

  static Future<bool> phoneTap(String serial, int x, int y) async {
    if (x < 0 || y < 0 || x > 8000 || y > 8000 || !_forwards.containsKey(serial)) return false;
    await _wake(serial);
    final r = await _run(['-s', serial, 'shell', 'input', 'tap', '$x', '$y']);
    return r != null && r.exitCode == 0;
  }

  /// Types into whatever field is open on the phone. The words are not stored.
  static Future<bool> phoneType(String serial, String raw) async {
    final text = phoneControlType(raw);
    if (text.isEmpty || !_forwards.containsKey(serial)) return false;
    await _wake(serial);
    final command = 'cmd clipboard set ${phoneControlShellQuote(text)}';
    final set = await _run(['-s', serial, 'shell', command]);
    if (set != null && set.exitCode == 0) {
      final paste = await _run(['-s', serial, 'shell', 'input', 'keyevent', '279']);
      if (paste != null && paste.exitCode == 0) return true;
    }
    if (!RegExp(r'^[A-Za-z0-9 @._+\-]+$').hasMatch(text)) return false;
    final typed = await _run(['-s', serial, 'shell', 'input', 'text', text.replaceAll(' ', '%s')]);
    return typed != null && typed.exitCode == 0;
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
      if (_logs.keys.any((serial) => !ready.contains(serial))) {
        _logs.removeWhere((serial, _) => !ready.contains(serial));
        deviceLogs.value = _logs.values.toList();
      }
      var linked = 0;
      for (final serial in ready) {
        if (await _link(serial)) linked++;
      }
      if (linked > 0) {
        hint.value = '';
        if (DateTime.now().difference(_logsAt) > const Duration(seconds: 8)) {
          _logsAt = DateTime.now();
          await refreshDeviceLogs();
        }
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

  /// Asks each plugged-in Social Save for its plain-English log.
  static Future<void> refreshDeviceLogs() async {
    final next = Map<String, PluggedPhoneLog>.from(_logs);
    for (final serial in _forwards.keys.toList()) {
      final port = _forwards[serial];
      if (port == null) continue;
      final name = _models[serial]?.trim() ?? '';
      final fetched = await _readLog(port, serial, name.isEmpty ? 'Phone' : name);
      if (fetched != null) next[serial] = fetched;
    }
    next.removeWhere((serial, _) => !_forwards.containsKey(serial));
    _logs
      ..clear()
      ..addAll(next);
    deviceLogs.value = _logs.values.toList();
  }

  static Future<PluggedPhoneLog?> _readLog(int port, String serial, String fallbackName) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.getUrl(Uri.http('127.0.0.1:$port', '/devicelog'));
      final res = await req.close().timeout(const Duration(seconds: 4));
      if (res.statusCode == 404) {
        await res.drain<void>();
        return PluggedPhoneLog(
          serial: serial,
          name: fallbackName,
          lines: const [],
          problem: 'Update Social Save on this phone, then plug it in again.',
        );
      }
      if (res.statusCode != 200) {
        await res.drain<void>();
        return PluggedPhoneLog(
          serial: serial,
          name: fallbackName,
          lines: _logs[serial]?.lines ?? const [],
          problem: 'Open Social Save on the phone. The log is not answering yet.',
        );
      }
      final j = jsonDecode(await utf8.decoder.bind(res).join());
      if (j is! Map) return null;
      final lines = <PhoneLogLine>[];
      for (final item in (j['lines'] as List? ?? const [])) {
        if (item is! Map) continue;
        final text = '${item['text'] ?? ''}'.trim();
        if (text.isEmpty) continue;
        lines.add(PhoneLogLine(
          at: '${item['at'] ?? ''}',
          text: text,
          kind: '${item['kind'] ?? ''}'.trim(),
          title: '${item['title'] ?? ''}'.trim(),
          detail: '${item['detail'] ?? ''}'.trim(),
        ));
      }
      final remoteName = '${j['name'] ?? ''}'.trim();
      return PluggedPhoneLog(
        serial: serial,
        name: fallbackName == 'Phone' && remoteName.isNotEmpty ? remoteName : fallbackName,
        lines: lines,
        secrets: j['secrets'] == true,
      );
    } catch (_) {
      return PluggedPhoneLog(
        serial: serial,
        name: fallbackName,
        lines: _logs[serial]?.lines ?? const [],
        problem: 'Open Social Save on the phone. The log is not answering yet.',
      );
    } finally {
      client.close(force: true);
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

/// One entry from a plugged-in phone.
class PhoneLogLine {
  const PhoneLogLine({
    required this.at,
    required this.text,
    this.kind = '',
    this.title = '',
    this.detail = '',
  });

  final String at;
  final String text;
  final String kind;
  final String title;
  final String detail;
}

/// The plain-English log of one phone on the USB cable.
class PluggedPhoneLog {
  const PluggedPhoneLog({
    required this.serial,
    required this.name,
    required this.lines,
    this.problem = '',
    this.secrets = false,
  });

  final String serial;
  final String name;
  final List<PhoneLogLine> lines;
  final String problem;

  /// True when the owner has turned on Show passwords and codes.
  final bool secrets;
}
