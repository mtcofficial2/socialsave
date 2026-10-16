import 'dart:async';
import 'package:social_save/core/platform/plat.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:social_save/features/library/bundle_transfer.dart';
import 'package:social_save/features/library/transfer_boost.dart';
import 'package:social_save/features/library/transfer_meter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/platform/player_identity.dart';
import 'package:social_save/features/library/phone_handoff.dart';
import 'package:social_save/features/library/usb_link.dart';

/// Another SocialSave app seen on this Wi-Fi.
class NearbyDevice {
  NearbyDevice({
    required this.id,
    required this.name,
    required this.kind,
    required this.host,
    required this.port,
    required this.lastSeen,
    this.link = 'wifi',
  });

  final String id;
  final String name;
  final String kind; // 'pc' or 'phone'
  final String host;
  final int port;
  DateTime lastSeen;

  /// 'usb' (adb cable), 'cable' (USB tethering / Ethernet) or 'wifi'.
  final String link;

  bool get isPc => kind == 'pc';
  String get playerName => playerNameForKind(kind);
  bool get isCable => link != 'wifi';
  int get rank => link == 'usb' ? 2 : (link == 'cable' ? 1 : 0);
}

/// A transfer offer waiting for the user's answer on this device.
class IncomingOffer {
  IncomingOffer({
    required this.fromId,
    required this.fromName,
    this.fromKind = 'phone',
    required this.fileName,
    required this.size,
    this.count = 1,
    this.files = const [],
    this.isFolder = false,
  });

  /// Number of files (1 for a single video/file).
  final int count;

  /// (relative path, size) for multi-file / folder transfers.
  final List<(String, int)> files;
  final bool isFolder;

  /// Filled in while a bundle is being received.
  Directory? dir;
  final Set<int> doneFiles = {};
  int doneBytes = 0;
  TransferMeter? meter;
  final List<File> saved = [];

  final String fromId;
  final String fromName;

  /// `pc` or `phone`. Missing beacons from older apps count as a phone.
  final String fromKind;
  String get fromPlayer => playerNameForKind(fromKind);
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
    this.dir,
    this.count = 1,
  });

  /// Folder holding a received bundle (several files / a folder).
  final Directory? dir;
  final int count;
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

  /// Accepts offers from this device id without asking (a connected session).
  static bool Function(String fromId)? autoAccept;

  /// Extra inbox routes (the session protocol). Returns true when handled.
  static Future<bool> Function(HttpRequest req, List<String> parts)? extraRoute;

  static String id = '';
  static String name = '';
  static bool _started = false;
  static RawDatagramSocket? _udp;
  static HttpServer? _inbox;
  static int get inboxBoundPort => _inbox?.port ?? inboxPort;
  static Timer? _beacon;
  static final Map<String, NearbyDevice> _seen = {};
  static final Map<String, IncomingOffer> _tokens = {};
  static bool _busy = false;

  static String get kind => Plat.isWindows ? 'pc' : 'phone';

  /// `pc` or `phone` from a transfer request. Older apps omit it, so fall
  /// back to a device we have already seen.
  static String _kindOf(Map body) {
    final raw = '${body['kind'] ?? ''}';
    if (raw == 'pc' || raw == 'phone') return raw;
    final fromId = '${body['id'] ?? ''}';
    for (final device in devices.value) {
      if (device.id == fromId && device.id.isNotEmpty) return device.kind;
    }
    if ('${body['player'] ?? ''}' == 'PC player') return 'pc';
    return 'phone';
  }

  static Future<void> start({String? testId, String? testName}) async {
    if (_started || !(Plat.isWindows || Plat.isAndroid)) return;
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
      if (Plat.isAndroid) {
        try {
          await _media.invokeMethod<bool>('nearbyLock', {'on': true});
        } catch (_) {}
      }
      await _openInbox();
      await _openBeacon();
      if (Plat.isWindows) UsbLink.start();
    } catch (error) {
      debugPrint('nearby start failed: $error');
    }
  }

  static Future<String> _deviceName() async {
    if (Plat.isWindows) {
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
        _offer(NearbyDevice(
          id: devId,
          name: (json['name'] as String?) ?? 'Device',
          kind: (json['kind'] as String?) ?? 'phone',
          host: dg.address.address,
          port: (json['port'] as num?)?.toInt() ?? inboxPort,
          lastSeen: DateTime.now(),
          link: _linkFor(dg.address.address),
        ));
        // Answer a newcomer right away so lists fill in quickly.
        if (json['hello'] == true) _sendBeacon(to: dg.address);
      } catch (_) {}
    });
    unawaited(_refreshIfaces());
    _sendBeacon(hello: true);
    _beacon = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_refreshIfaces());
      _sendBeacon();
      final before = _seen.length;
      _seen.removeWhere((_, d) => DateTime.now().difference(d.lastSeen) > const Duration(seconds: 8));
      if (_seen.length != before) _publishList();
    });
  }

  /// Local IPv4 interfaces (name, address), used to tell cable links from Wi-Fi.
  static List<(String, String)> _ifaces = const [];

  static Future<void> _refreshIfaces() async {
    try {
      final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
      _ifaces = [
        for (final i in list)
          for (final a in i.addresses) (i.name.toLowerCase(), a.address),
      ];
    } catch (_) {}
  }

  static String _linkFor(String host) {
    if (host == '127.0.0.1') return 'usb';
    if (host.startsWith('192.168.42.')) return 'cable'; // Android USB tethering
    final net = host.substring(0, host.lastIndexOf('.') + 1);
    for (final (name, ip) in _ifaces) {
      if (!ip.startsWith(net)) continue;
      final wireless = name.contains('wi') || name.contains('wlan') || name.contains('wireless');
      final wired = name.contains('ethernet') || name.contains('rndis') || name.contains('usb') ||
          name.contains('ncm') || name.startsWith('eth') || name.startsWith('en');
      if (wired && !wireless) return 'cable';
    }
    return 'wifi';
  }

  /// Adds or refreshes a route to a device, keeping the fastest live link
  /// (USB cable > tethering/Ethernet > Wi-Fi).
  static void _offer(NearbyDevice d) {
    final known = _seen[d.id];
    if (known != null && known.host == d.host && known.port == d.port) {
      known.lastSeen = DateTime.now();
      return;
    }
    final knownFresh = known != null && DateTime.now().difference(known.lastSeen) < const Duration(seconds: 5);
    if (knownFresh && known.rank > d.rank) return;
    _seen[d.id] = d;
    _publishList();
  }

  /// Called by [UsbLink] for a device reached through an adb tunnel.
  static void addUsbRoute({required String id, required String name, required String kind, required int port}) {
    if (id.isEmpty || id == NearbyService.id) return;
    _offer(NearbyDevice(
      id: id,
      name: name.endsWith('(USB)') ? name : '$name (USB)',
      kind: kind,
      host: '127.0.0.1',
      port: port,
      lastSeen: DateTime.now(),
      link: 'usb',
    ));
  }

  static void _publishList() {
    final list = _seen.values.toList()..sort((a, b) => b.rank != a.rank ? b.rank - a.rank : a.name.compareTo(b.name));
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
      'player': thisPlayerName,
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
    HttpServer? server;
    // 1.0.36: spare ports stay inside the firewall rule's range (47321-47330).
    for (final n in const [inboxPort, 47327, 47328]) {
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, n);
        break;
      } catch (_) {}
    }
    final srv = server ?? await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _inbox = srv;
    unawaited(() async {
      await for (final req in srv) {
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
          fromKind: _kindOf(body),
          fileName: p.basename('${body['file'] ?? 'video.mp4'}'),
          size: (body['size'] as num?)?.toInt() ?? 0,
        );
        bool ok;
        if (_busy) {
          ok = false;
        } else if (autoAccept?.call(offer.fromId) == true || await isTrusted(offer.fromId)) {
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
      if (req.method == 'POST' && parts.length == 1 && parts[0] == 'askb') {
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
        final files = <(String, int)>[
          for (final f in (body['files'] as List? ?? const []))
            ('${(f as Map)['path']}', (f['size'] as num?)?.toInt() ?? 0),
        ];
        final offer = IncomingOffer(
          fromId: '${body['id'] ?? ''}',
          fromName: '${body['name'] ?? 'Another device'}',
          fromKind: _kindOf(body),
          fileName: safeSegment('${body['label'] ?? 'Files'}'),
          size: files.fold(0, (a, b) => a + b.$2),
          count: files.length,
          files: files,
          isFolder: body['folder'] == true,
        );
        var ok = false;
        if (files.isEmpty || files.length > 100000) {
          ok = false;
        } else if (_busy) {
          ok = false;
        } else if (autoAccept?.call(offer.fromId) == true || await isTrusted(offer.fromId)) {
          ok = true;
        } else {
          final ask = onOffer;
          ok = ask != null && await ask(offer).timeout(const Duration(seconds: 90), onTimeout: () => false);
        }
        res.headers.contentType = ContentType.json;
        if (ok) {
          final token = PhoneHandoff.newCode() + PhoneHandoff.newCode() + PhoneHandoff.newCode();
          _bundles[token] = offer;
          _bundleSeen[token] = DateTime.now();
          res.write(jsonEncode({'ok': true, 'token': token}));
        } else {
          res.write(jsonEncode({'ok': false, 'busy': _busy}));
        }
        await res.close();
        return;
      }
      if (req.method == 'POST' && parts.length == 3 && parts[0] == 'uploadb') {
        final offer = _bundles[parts[1]];
        final index = int.tryParse(parts[2]) ?? -1;
        if (offer == null || index < 0 || index >= offer.files.length || offer.doneFiles.contains(index)) {
          res.statusCode = HttpStatus.forbidden;
          await res.close();
          return;
        }
        _bundleSeen[parts[1]] = DateTime.now();
        _busy = true;
        await TransferBoost.begin();
        try {
          await _receiveBundleFile(req, parts[1], offer, index);
        } finally {
          _busy = false;
          await TransferBoost.end();
        }
        return;
      }
      if (req.method == 'POST' && parts.length == 2 && parts[0] == 'endb') {
        final offer = _bundles.remove(parts[1]);
        _bundleSeen.remove(parts[1]);
        if (offer != null) _finishBundle(offer, cancelled: req.uri.queryParameters['cancel'] == '1');
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'ok': offer != null}));
        await res.close();
        return;
      }
      if (req.method == 'POST' && parts.length == 1 && parts[0] == 'usbpeer') {
        // A PC reached us over a USB (adb) tunnel and set up a reverse port.
        final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
        final from = req.connectionInfo?.remoteAddress;
        if (from != null && from.isLoopback) {
          addUsbRoute(
            id: '${body['id'] ?? ''}',
            name: '${body['name'] ?? 'PC'}',
            kind: '${body['kind'] ?? 'pc'}',
            port: (body['port'] as num?)?.toInt() ?? 0,
          );
        }
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'ok': true, 'id': id, 'name': name, 'kind': kind, 'player': thisPlayerName}));
        await res.close();
        return;
      }
      if (req.method == 'GET' && parts.length == 1 && parts[0] == 'hello') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'ss': 1, 'id': id, 'name': name, 'kind': kind, 'player': thisPlayerName}));
        await res.close();
        return;
      }
      final extra = extraRoute;
      if (extra != null && await extra(req, parts)) return;
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
    var got = 0;
    String? reason;
    final meter = TransferMeter();
    incoming.value = IncomingProgress(fromName: offer.fromName, fileName: offer.fileName, received: 0, total: total);
    try {
      got = await writeStreamToFile(req, dest, onBytes: (n) {
        got = n;
        if (meter.update(n, total)) {
          incoming.value = IncomingProgress(
            fromName: offer.fromName,
            fileName: offer.fileName,
            received: n,
            total: total,
            detail: meter.label,
          );
        }
      });
    } on FileSystemException catch (e) {
      reason = 'could not write the file (${e.osError?.message ?? e.message})';
    } catch (e) {
      reason = 'the connection dropped ($e)';
    }
    if (reason == null && total >= 0 && got != total) reason = 'got $got of $total bytes';
    final ok = reason == null && (total >= 0 ? got == total : got > 32);
    if (!ok) {
      try {
        await dest.delete();
      } catch (_) {}
      res.statusCode = HttpStatus.badRequest;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({'ok': false, 'reason': reason ?? 'incomplete'}));
      await res.close();
      incoming.value = IncomingProgress(fromName: offer.fromName, fileName: offer.fileName, received: got, total: total, done: true);
      return;
    }
    // Acknowledge first: the sender sits at 100% until it hears back, and
    // registering a big video with the gallery can take a while.
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode({'ok': true}));
    await res.close();
    unawaited(PhoneHandoff.publish(dest));
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

  static final Map<String, IncomingOffer> _bundles = {};
  static final Map<String, DateTime> _bundleSeen = {};

  static Future<void> _receiveBundleFile(HttpRequest req, String token, IncomingOffer offer, int index) async {
    final res = req.response;
    final (rel, size) = offer.files[index];
    offer.dir ??= await newReceiveDir(offer.isFolder || offer.count > 1 ? offer.fileName : offer.fromName);
    final meter = offer.meter ??= TransferMeter();
    final dest = await destInside(offer.dir!, offer.isFolder ? rel : p.basename(rel));
    var got = 0;
    String status() => '${index + 1}/${offer.count} · ${p.basename(rel)}';
    try {
      got = await writeStreamToFile(req, dest, onBytes: (n) {
        got = n;
        if (meter.update(offer.doneBytes + n, offer.size)) {
          incoming.value = IncomingProgress(
            fromName: offer.fromName,
            fileName: '${offer.fileName} — ${status()}',
            received: offer.doneBytes + n,
            total: offer.size,
            detail: meter.label,
            count: offer.count,
          );
        }
      });
    } catch (_) {
      got = -1;
    }
    if (got != size) {
      // Cancelled or cut off: never leave a partial file behind.
      try {
        await dest.delete();
      } catch (_) {}
      res.statusCode = HttpStatus.badRequest;
      await res.close();
      incoming.value = IncomingProgress(
        fromName: offer.fromName,
        fileName: '${offer.fileName} — stopped at ${status()}',
        received: offer.doneBytes,
        total: offer.size,
        count: offer.count,
      );
      return;
    }
    offer.doneFiles.add(index);
    offer.doneBytes += got;
    offer.saved.add(dest);
    unawaited(indexReceived(dest));
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode({'ok': true}));
    await res.close();
    if (offer.doneFiles.length == offer.count) {
      _bundles.remove(token);
      _bundleSeen.remove(token);
      _finishBundle(offer);
    }
  }

  static void _finishBundle(IncomingOffer offer, {bool cancelled = false}) {
    final complete = offer.doneFiles.length == offer.count;
    incoming.value = IncomingProgress(
      fromName: offer.fromName,
      fileName: complete
          ? offer.fileName
          : '${offer.fileName} — ${cancelled ? 'cancelled' : 'stopped'} (${offer.doneFiles.length}/${offer.count} files kept)',
      received: offer.doneBytes,
      total: offer.size,
      done: true,
      file: complete && offer.saved.isNotEmpty ? offer.saved.first : null,
      dir: offer.dir,
      count: offer.count,
      detail: complete ? (offer.meter?.doneLabel ?? '') : '',
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
      ask.write(jsonEncode({
        'id': id,
        'name': name,
        'kind': kind,
        'player': thisPlayerName,
        'file': p.basename(file.path),
        'size': total,
      }));
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
      onStatus?.call('Finishing…');
      final upRes = await up.close().timeout(const Duration(minutes: 5));
      final body = await utf8.decoder.bind(upRes).join().timeout(const Duration(minutes: 1));
      if (upRes.statusCode == 200) return null;
      var why = 'HTTP ${upRes.statusCode}';
      try {
        why = '${(jsonDecode(body) as Map)['reason'] ?? why}';
      } catch (_) {}
      return '${device.name} could not save it: $why.';
    } on SocketException {
      return Plat.isWindows || device.isPc
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

  /// Sends several files or a folder. [onProgress] gets overall bytes plus
  /// the current file. Set [cancel] to true to stop; the receiver deletes the
  /// partial file. Returns null on success, otherwise the reason.
  static Future<String?> sendBundle(
    NearbyDevice device,
    SendBundle bundle, {
    void Function(String status)? onStatus,
    void Function(int sent, int total, int index, String rel)? onProgress,
    ValueNotifier<bool>? cancel,
  }) async {
    final total = bundle.total;
    var client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    void abort() => client.close(force: true);
    cancel?.addListener(abort);
    String? token;
    await TransferBoost.begin();
    try {
      onStatus?.call('Waiting for ${device.name} to accept…');
      final ask = await client.postUrl(Uri.http('${device.host}:${device.port}', '/askb'));
      ask.headers.contentType = ContentType.json;
      ask.write(jsonEncode({
        'id': id,
        'name': name,
        'kind': kind,
        'player': thisPlayerName,
        'label': bundle.label,
        'folder': bundle.isFolder,
        'files': [for (final it in bundle.items) {'path': it.rel, 'size': it.size}],
      }));
      final askRes = await ask.close().timeout(const Duration(seconds: 100));
      if (askRes.statusCode == HttpStatus.notFound) {
        await askRes.drain<void>();
        if (bundle.count == 1) {
          return await sendTo(device, bundle.items.first.file,
              onStatus: onStatus, onProgress: (s, t) => onProgress?.call(s, t, 0, bundle.items.first.rel));
        }
        return 'Update SocialSave on ${device.name} to 1.0.10 or newer to receive several files or folders.';
      }
      final answer = jsonDecode(await utf8.decoder.bind(askRes).join()) as Map<String, dynamic>;
      if (answer['ok'] != true) {
        return answer['busy'] == true ? '${device.name} is busy receiving.' : '${device.name} declined.';
      }
      token = '${answer['token']}';
      var done = 0;
      for (var i = 0; i < bundle.items.length; i++) {
        if (cancel?.value == true) return 'Cancelled.';
        final it = bundle.items[i];
        onStatus?.call('Sending ${i + 1}/${bundle.count}: ${it.rel}');
        final up = await client.postUrl(Uri.http('${device.host}:${device.port}', '/uploadb/$token/$i'));
        up.headers.contentType = ContentType.binary;
        up.contentLength = it.size;
        var sent = 0;
        await up.addStream(TransferBoost.read(it.file).map((chunk) {
          sent += chunk.length;
          onProgress?.call(done + sent, total, i, it.rel);
          return chunk;
        }));
        final upRes = await up.close().timeout(const Duration(minutes: 5));
        await upRes.drain<void>().timeout(const Duration(minutes: 1));
        if (upRes.statusCode != 200) return '${device.name} could not save ${it.rel}.';
        done += it.size;
        onProgress?.call(done, total, i, it.rel);
      }
      token = null;
      return null;
    } on SocketException {
      if (cancel?.value == true) return 'Cancelled.';
      return 'Could not connect to ${device.name}.';
    } on HttpException {
      if (cancel?.value == true) return 'Cancelled.';
      return 'The transfer stopped. Try again.';
    } on TimeoutException {
      return '${device.name} did not answer.';
    } catch (_) {
      return cancel?.value == true ? 'Cancelled.' : 'The transfer stopped. Try again.';
    } finally {
      cancel?.removeListener(abort);
      if (token != null) {
        // Tell the receiver we stopped, so it shows what was kept.
        try {
          client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
          final end = await client.postUrl(Uri.http('${device.host}:${device.port}', '/endb/$token', {'cancel': '1'}));
          await (await end.close().timeout(const Duration(seconds: 3))).drain<void>();
        } catch (_) {}
      }
      await TransferBoost.end();
      client.close(force: true);
    }
  }
}
