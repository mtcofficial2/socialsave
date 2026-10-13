import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:social_save/features/library/transfer_boost.dart';
import 'package:social_save/features/library/transfer_meter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/features/library/phone_handoff.dart';

/// Another SocialSave app seen on this Wi-Fi.
class NearbyDevice {
  NearbyDevice({
    required this.id,
    required this.name,
    required this.kind,
    required this.host,
    required this.port,
    required this.lastSeen,
  });

  final String id;
  final String name;
  final String kind; // 'pc' or 'phone'
  final String host;
  final int port;
  DateTime lastSeen;

  bool get isPc => kind == 'pc';
}

/// A transfer offer waiting for the user's answer on this device.
class IncomingOffer {
  IncomingOffer({
    required this.fromId,
    required this.fromName,
    required this.fileName,
    required this.size,
  });

  final String fromId;
  final String fromName;
  final String fileName;
  final int size;
  final Completer<bool> answer = Completer<bool>();
}

/// Progress of the file this device is currently receiving.
class IncomingProgress {
  const IncomingProgress({
    required this.fromName,
    required this.fileName,
    required this.received,
    required this.total,
    this.done = false,
    this.file,
    this.detail = '',
  });

  final String detail;
  final String fromName;
  final String fileName;
  final int received;
  final int total;
  final bool done;
  final File? file;

  double? get fraction => total > 0 ? received / total : null;
}

/// Finds other SocialSave apps on the same Wi-Fi and receives files from them.
///
/// Every app broadcasts a small beacon on UDP [beaconPort] every 2 seconds
/// and keeps an inbox on TCP [inboxPort]. To send, the sender asks the
/// receiver's inbox; the receiver's user accepts, the inbox hands back a
/// one-time token, and the sender uploads with it. Only the receiver accepts
/// connections, so a PC can send without a firewall rule.
class NearbyService {
  NearbyService._();

  static const int beaconPort = 47324;
  static const int inboxPort = 47325;
  static const _media = MethodChannel('socialsave/media');
  static const _trustedKey = 'socialsave_nearby_trusted';

  static final ValueNotifier<List<NearbyDevice>> devices = ValueNotifier(const []);
  static final ValueNotifier<IncomingProgress?> incoming = ValueNotifier(null);

  /// Set by the UI: shows "X wants to send you…" and returns the answer.
  static Future<bool> Function(IncomingOffer offer)? onOffer;

  static String id = '';
  static String name = '';
  static bool _started = false;
  static RawDatagramSocket? _udp;
  static HttpServer? _inbox;
  static Timer? _beacon;
  static final Map<String, NearbyDevice> _seen = {};
  static final Map<String, IncomingOffer> _tokens = {};
  static bool _busy = false;

  static String get kind => Platform.isWindows ? 'pc' : 'phone';

  static Future<void> start({String? testId, String? testName}) async {
    if (_started || !(Platform.isWindows || Platform.isAndroid)) return;
    _started = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      id = testId ?? prefs.getString('socialsave_nearby_id') ?? '';
      if (id.isEmpty) {
        final r = Random.secure();
        id = List.generate(8, (_) => r.nextInt(16).toRadixString(16)).join();
        await prefs.setString('socialsave_nearby_id', id);
      }
      name = testName ?? await _deviceName();
      if (Platform.isAndroid) {
        try {
          await _media.invokeMethod<bool>('nearbyLock', {'on': true});
        } catch (_) {}
      }
      await _openInbox();
      await _openBeacon();
    } catch (error) {
      debugPrint('nearby start failed: $error');
    }
  }

  static Future<String> _deviceName() async {
    if (Platform.isWindows) {
      final n = Platform.environment['COMPUTERNAME'] ?? Platform.localHostname;
      return n.isEmpty ? 'Windows PC' : n;
    }
    try {
      final n = await _media.invokeMethod<String>('deviceName');
      if (n != null && n.trim().isNotEmpty) return n.trim();
    } catch (_) {}
    return 'Android phone';
  }

  // ---------------- discovery ----------------

  static Future<void> _openBeacon() async {
    final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, beaconPort, reuseAddress: true);
    udp.broadcastEnabled = true;
    _udp = udp;
    udp.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = udp.receive();
      if (dg == null) return;
      try {
        final json = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
        if (json['ss'] != 1 || json['id'] == id) return;
        final devId = json['id'] as String;
        final known = _seen[devId];
        if (known != null && known.host == dg.address.address) {
          known.lastSeen = DateTime.now();
        } else {
          _seen[devId] = NearbyDevice(
            id: devId,
            name: (json['name'] as String?) ?? 'Device',
            kind: (json['kind'] as String?) ?? 'phone',
            host: dg.address.address,
            port: (json['port'] as num?)?.toInt() ?? inboxPort,
            lastSeen: DateTime.now(),
          );
          _publishList();
        }
        // Answer a newcomer right away so lists fill in quickly.
        if (json['hello'] == true) _sendBeacon(to: dg.address);
      } catch (_) {}
    });
    _sendBeacon(hello: true);
    _beacon = Timer.periodic(const Duration(seconds: 2), (_) {
      _sendBeacon();
      final before = _seen.length;
      _seen.removeWhere((_, d) => DateTime.now().difference(d.lastSeen) > const Duration(seconds: 8));
      if (_seen.length != before) _publishList();
    });
  }

  static void _publishList() {
    final list = _seen.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    devices.value = list;
  }

  static Future<void> _sendBeacon({bool hello = false, InternetAddress? to}) async {
    final udp = _udp;
    if (udp == null) return;
    final data = utf8.encode(jsonEncode({
      'ss': 1,
      'id': id,
      'name': name,
      'kind': kind,
      'port': _inbox?.port ?? inboxPort,
      if (hello) 'hello': true,
    }));
    final targets = <InternetAddress>{};
    if (to != null) {
      targets.add(to);
    } else {
      targets.add(InternetAddress('255.255.255.255'));
      try {
        for (final ip in await PhoneHandoff.lanIps()) {
          final q = ip.split('.');
          targets.add(InternetAddress('${q[0]}.${q[1]}.${q[2]}.255'));
        }
      } catch (_) {}
    }
    for (final t in targets) {
      try {
        udp.send(data, t, beaconPort);
      } catch (_) {}
    }
  }

  /// Ask for an immediate refresh (e.g. when a Send screen opens).
  static void ping() => unawaited(_sendBeacon(hello: true));

  // ---------------- receiving ----------------

  static Future<void> _openInbox() async {
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, inboxPort);
    } catch (_) {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _inbox = server;
    unawaited(() async {
      await for (final req in server) {
        unawaited(_handle(req));
      }
    }());
  }

  static Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final parts = req.uri.pathSegments;
      if (req.method == 'POST' && parts.length == 1 && parts[0] == 'ask') {
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
        final offer = IncomingOffer(
          fromId: '${body['id'] ?? ''}',
          fromName: '${body['name'] ?? 'Another device'}',
          fileName: p.basename('${body['file'] ?? 'video.mp4'}'),
          size: (body['size'] as num?)?.toInt() ?? 0,
        );
        bool ok;
        if (_busy) {
          ok = false;
        } else if (await isTrusted(offer.fromId)) {
          ok = true;
        } else {
          final ask = onOffer;
          ok = ask == null
              ? false
              : await ask(offer).timeout(const Duration(seconds: 90), onTimeout: () => false);
        }
        res.headers.contentType = ContentType.json;
        if (ok) {
          final token = PhoneHandoff.newCode() + PhoneHandoff.newCode();
          _tokens[token] = offer;
          Timer(const Duration(minutes: 2), () => _tokens.remove(token));
          res.write(jsonEncode({'ok': true, 'token': token}));
        } else {
          res.write(jsonEncode({'ok': false, 'busy': _busy}));
        }
        await res.close();
        return;
      }
      if (req.method == 'POST' && parts.length == 2 && parts[0] == 'upload') {
        final offer = _tokens.remove(parts[1]);
        if (offer == null || _busy) {
          res.statusCode = HttpStatus.forbidden;
          await res.close();
          return;
        }
        _busy = true;
        await TransferBoost.begin();
        try {
          await _receive(req, offer);
        } finally {
          _busy = false;
          await TransferBoost.end();
        }
        return;
      }
      if (req.method == 'GET' && parts.length == 1 && parts[0] == 'hello') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'ss': 1, 'id': id, 'name': name, 'kind': kind}));
        await res.close();
        return;
      }
      res.statusCode = HttpStatus.notFound;
      await res.close();
    } catch (_) {
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  static Future<void> _receive(HttpRequest req, IncomingOffer offer) async {
    final res = req.response;
    final total = req.contentLength > 0 ? req.contentLength : offer.size;
    final dest = await PhoneHandoff.destFor(offer.fileName);
    final sink = dest.openWrite();
    var got = 0;
    final meter = TransferMeter();
    incoming.value = IncomingProgress(fromName: offer.fromName, fileName: offer.fileName, received: 0, total: total);
    try {
      await for (final chunk in req) {
        sink.add(chunk);
        got += chunk.length;
        if (meter.update(got, total)) {
          incoming.value = IncomingProgress(
            fromName: offer.fromName,
            fileName: offer.fileName,
            received: got,
            total: total,
            detail: meter.label,
          );
        }
      }
      await sink.close();
    } catch (_) {
      await sink.close();
    }
    final ok = got > 32 && (total <= 0 || got == total);
    if (!ok) {
      try {
        await dest.delete();
      } catch (_) {}
      res.statusCode = HttpStatus.badRequest;
      await res.close();
      incoming.value = IncomingProgress(fromName: offer.fromName, fileName: offer.fileName, received: got, total: total, done: true);
      return;
    }
    await PhoneHandoff.publish(dest);
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode({'ok': true}));
    await res.close();
    incoming.value = IncomingProgress(
      fromName: offer.fromName,
      fileName: offer.fileName,
      received: got,
      total: total,
      done: true,
      file: dest,
      detail: meter.doneLabel,
    );
  }

  static Future<bool> isTrusted(String deviceId) async {
    if (deviceId.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_trustedKey) ?? const []).contains(deviceId);
  }

  static Future<void> trust(String deviceId) async {
    if (deviceId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_trustedKey) ?? <String>[];
    if (!list.contains(deviceId)) {
      list.add(deviceId);
      await prefs.setStringList(_trustedKey, list);
    }
  }

  // ---------------- sending ----------------

  /// Sends [file] to [device]. [onStatus] gets short human messages.
  /// Returns null on success, otherwise the reason.
  static Future<String?> sendTo(
    NearbyDevice device,
    File file, {
    void Function(String status)? onStatus,
    void Function(int sent, int total)? onProgress,
  }) async {
    final total = await file.length();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    await TransferBoost.begin();
    try {
      onStatus?.call('Waiting for ${device.name} to accept…');
      final ask = await client.postUrl(Uri.http('${device.host}:${device.port}', '/ask'));
      ask.headers.contentType = ContentType.json;
      ask.write(jsonEncode({'id': id, 'name': name, 'file': p.basename(file.path), 'size': total}));
      final askRes = await ask.close().timeout(const Duration(seconds: 100));
      final answer = jsonDecode(await utf8.decoder.bind(askRes).join()) as Map<String, dynamic>;
      if (answer['ok'] != true) {
        return answer['busy'] == true ? '${device.name} is busy receiving.' : '${device.name} declined.';
      }
      onStatus?.call('Sending…');
      final up = await client.postUrl(Uri.http('${device.host}:${device.port}', '/upload/${answer['token']}'));
      up.headers.contentType = ContentType.binary;
      up.contentLength = total;
      var sent = 0;
      await up.addStream(TransferBoost.read(file).map((chunk) {
        sent += chunk.length;
        onProgress?.call(sent, total);
        return chunk;
      }));
      final upRes = await up.close();
      await upRes.drain<void>();
      return upRes.statusCode == 200 ? null : '${device.name} could not save it.';
    } on SocketException {
      return Platform.isWindows || device.isPc
          ? 'Could not connect to ${device.name}. If it is a PC, allow SocialSave in its Windows firewall prompt.'
          : 'Could not connect to ${device.name}. Stay on the same Wi-Fi.';
    } on TimeoutException {
      return '${device.name} did not answer.';
    } catch (_) {
      return 'The transfer stopped. Try again.';
    } finally {
      await TransferBoost.end();
      client.close(force: true);
    }
  }
}
