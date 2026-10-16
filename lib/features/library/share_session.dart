import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:social_save/features/library/hotspot_share.dart';
import 'package:social_save/features/library/nearby_service.dart';
import 'package:social_save/features/library/phone_handoff.dart';
import 'package:social_save/features/library/transfer_meter.dart';

/// The other device in a [ShareSession].
class SessionPeer {
  SessionPeer({required this.id, required this.name, required this.kind, required this.host, required this.port, required this.link});
  final String id;
  final String name;
  final String kind; // 'pc' or 'phone'
  String host;
  int port;

  /// 'hotspot', 'usb', 'cable' or 'wifi'.
  final String link;

  NearbyDevice get device => NearbyDevice(
        id: id,
        name: name,
        kind: kind,
        host: host,
        port: port,
        lastSeen: DateTime.now(),
        link: link == 'hotspot' ? 'wifi' : link,
      );

  String get linkLabel => switch (link) {
        'hotspot' => 'Hotspot',
        'usb' => 'USB cable',
        'cable' => 'Cable',
        _ => 'Wi-Fi',
      };
}

enum SessionItemState { queued, sending, receiving, done, failed }

/// One row in the session's transfer list.
class SessionItem {
  SessionItem({required this.outgoing, required this.name, this.size = 0, this.file, this.state = SessionItemState.queued});
  final int key = _nextKey++;
  static int _nextKey = 1;
  final bool outgoing;
  String name;
  int size;
  int done = 0;
  File? file;
  SessionItemState state;
  String detail = '';

  /// Live speed in bytes per second while active.
  double speed = 0;
  final DateTime at = DateTime.now();

  double? get fraction => size > 0 ? (done / size).clamp(0.0, 1.0) : null;
  bool get active => state == SessionItemState.sending || state == SessionItemState.receiving;
}

/// Xender-style connection between two SocialSave apps.
///
/// After one pairing (hotspot QR, or "Connect" on a nearby device) both apps
/// keep each other as the session peer: either side can send files at any
/// time, the other side accepts them automatically, and a heartbeat notices
/// when the other device goes away. Files still travel over the normal
/// nearby inbox (`/ask` + `/upload`), so nothing about saving changes.
///
/// Wire protocol (on the nearby inbox port):
/// * `POST /session/open`  {id, name, kind, port, pair?} -> {ok, token, id, name, kind}
/// * `POST /session/ping`  {token} -> 200 while the session lives, 410 after
/// * `POST /session/close` {token}
class ShareSession {
  ShareSession._();

  static final ValueNotifier<SessionPeer?> peer = ValueNotifier<SessionPeer?>(null);

  /// 'connected', 'reconnecting' or 'closed'.
  static final ValueNotifier<String> state = ValueNotifier<String>('closed');

  /// Why the last session ended (shown on the session screen).
  static String endReason = '';

  /// Bumped whenever [items] change.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);
  static final List<SessionItem> items = [];

  /// Asks the user whether [name] may connect. Set by the UI.
  static Future<bool> Function(String name, String kind)? onRequest;

  /// Called on this device when a session opens (to show the session screen).
  static void Function()? onOpened;

  /// While true, [onOpened] is not called (a dialog handles it itself).
  static int suppressAutoOpen = 0;

  /// True while the session screen is visible.
  static bool screenOpen = false;

  static String? _token;
  static String? _pairToken;
  static bool hostsHotspot = false;
  static bool joinedHotspot = false;
  static Timer? _beat;
  static int _misses = 0;
  static bool _pumping = false;
  static bool _installed = false;

  static bool get active => peer.value != null;

  static void install() {
    if (_installed) return;
    _installed = true;
    NearbyService.autoAccept = (fromId) => peer.value != null && peer.value!.id == fromId;
    NearbyService.extraRoute = _route;
    NearbyService.incoming.addListener(_onIncoming);
  }

  static void _changed() => revision.value++;

  static String _newToken() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  /// A one-time token for a QR pairing: whoever brings it back connects
  /// without a prompt.
  static String armPairing() => _pairToken = _newToken();

  // ------------------------------------------------------------ host side

  static Future<bool> _route(HttpRequest req, List<String> parts) async {
    if (parts.length != 2 || parts[0] != 'session' || req.method != 'POST') return false;
    final res = req.response;
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
    } catch (_) {
      body = const {};
    }
    res.headers.contentType = ContentType.json;
    switch (parts[1]) {
      case 'open':
        await _handleOpen(req, body);
      case 'ping':
        final ok = _token != null && body['token'] == _token;
        res.statusCode = ok ? HttpStatus.ok : HttpStatus.gone;
        res.write(jsonEncode({'ok': ok}));
        if (ok) _heard();
      case 'close':
        final ok = _token != null && body['token'] == _token;
        res.write(jsonEncode({'ok': ok}));
        if (ok) {
          final name = peer.value?.name ?? 'The other device';
          unawaited(Future<void>.delayed(Duration.zero, () => _end('$name disconnected.')));
        }
      default:
        res.statusCode = HttpStatus.notFound;
    }
    await res.close();
    return true;
  }

  static Future<void> _handleOpen(HttpRequest req, Map<String, dynamic> body) async {
    final res = req.response;
    final id = '${body['id'] ?? ''}';
    final name = '${body['name'] ?? 'Another device'}';
    final kind = '${body['kind'] ?? 'phone'}';
    final port = (body['port'] as num?)?.toInt() ?? NearbyService.inboxPort;
    final pair = body['pair'] as String?;
    if (id.isEmpty) {
      res.statusCode = HttpStatus.badRequest;
      res.write(jsonEncode({'ok': false}));
      return;
    }
    final current = peer.value;
    if (current != null && current.id != id) {
      res.write(jsonEncode({'ok': false, 'busy': true, 'with': current.name}));
      return;
    }
    var ok = current != null && current.id == id; // reconnect from the same device
    if (!ok && pair != null && pair == _pairToken) ok = true;
    if (!ok && await NearbyService.isTrusted(id)) ok = true;
    if (!ok) {
      final ask = onRequest;
      ok = ask != null && await ask(name, kind).timeout(const Duration(seconds: 60), onTimeout: () => false);
    }
    if (!ok) {
      res.write(jsonEncode({'ok': false}));
      return;
    }
    // How do we reach them? A known route (USB tunnel, Wi-Fi beacon) wins;
    // otherwise the address they called from plus their inbox port.
    final from = req.connectionInfo?.remoteAddress;
    String? host;
    var toPort = port;
    var link = pair != null && pair == _pairToken && hostsHotspotPending ? 'hotspot' : 'wifi';
    final known = NearbyService.devices.value.where((d) => d.id == id).toList()
      ..sort((a, b) => b.rank.compareTo(a.rank));
    if (from != null && from.isLoopback) {
      if (known.isEmpty) {
        res.write(jsonEncode({'ok': false, 'reason': 'no route back over USB'}));
        return;
      }
      host = known.first.host;
      toPort = known.first.port;
      link = known.first.link;
    } else if (from != null) {
      host = from.address;
      final same = known.where((d) => d.host == host).toList();
      if (same.isNotEmpty && link != 'hotspot') link = same.first.link;
    } else if (known.isNotEmpty) {
      host = known.first.host;
      toPort = known.first.port;
      link = known.first.link;
    }
    if (host == null) {
      res.write(jsonEncode({'ok': false}));
      return;
    }
    if (link == 'hotspot') hostsHotspot = true;
    _pairToken = null;
    final token = current != null ? _token! : _newToken();
    _start(SessionPeer(id: id, name: name, kind: kind, host: host, port: toPort, link: link), token);
    res.write(jsonEncode({
      'ok': true,
      'token': token,
      'id': NearbyService.id,
      'name': NearbyService.name,
      'kind': NearbyService.kind,
    }));
  }

  /// Set by the hotspot dialog while its QR is showing.
  static bool hostsHotspotPending = false;

  // ---------------------------------------------------------- joiner side

  /// Opens a session with the app listening on [host]:[port].
  /// Returns null on success, otherwise a short reason.
  static Future<String?> connect({
    required String host,
    required int port,
    String? pair,
    String link = 'wifi',
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.postUrl(Uri.http('$host:$port', '/session/open'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'id': NearbyService.id,
        'name': NearbyService.name,
        'kind': NearbyService.kind,
        'port': NearbyService.inboxBoundPort,
        if (pair != null) 'pair': pair,
      }));
      final res = await req.close().timeout(const Duration(seconds: 75));
      final text = await utf8.decoder.bind(res).join();
      if (res.statusCode == HttpStatus.notFound) {
        return 'Update SocialSave on the other device to 1.0.31 or newer to stay connected.';
      }
      final j = jsonDecode(text) as Map<String, dynamic>;
      if (j['ok'] != true) {
        if (j['busy'] == true) return 'The other device is already connected to ${j['with'] ?? 'another device'}.';
        return 'The other device did not accept the connection.';
      }
      _start(
        SessionPeer(
          id: '${j['id']}',
          name: '${j['name'] ?? 'Other device'}',
          kind: '${j['kind'] ?? 'phone'}',
          host: host,
          port: port,
          link: link,
        ),
        '${j['token']}',
      );
      return null;
    } on TimeoutException {
      return 'The other device did not answer.';
    } catch (_) {
      return 'Could not reach the other device.';
    } finally {
      client.close(force: true);
    }
  }

  // ------------------------------------------------------------- session

  static void _start(SessionPeer p, String token) {
    final fresh = peer.value == null;
    _token = token;
    peer.value = p;
    state.value = 'connected';
    endReason = '';
    _misses = 0;
    if (fresh) {
      items.clear();
      _changed();
    }
    _beat?.cancel();
    _beat = Timer.periodic(const Duration(seconds: 3), (_) => unawaited(_ping()));
    debugPrint('[session] connected to ${p.name} ${p.host}:${p.port} via ${p.link}');
    if (fresh && suppressAutoOpen == 0) onOpened?.call();
  }

  static void _heard() {
    _misses = 0;
    if (state.value == 'reconnecting') state.value = 'connected';
  }

  static Future<void> _ping() async {
    final p = peer.value;
    final token = _token;
    if (p == null || token == null) return;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.postUrl(Uri.http('${p.host}:${p.port}', '/session/ping'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'token': token}));
      final res = await req.close().timeout(const Duration(seconds: 5));
      await res.drain<void>();
      if (res.statusCode == HttpStatus.gone) {
        await _end('${p.name} ended the connection.');
        return;
      }
      if (res.statusCode == 200) _heard();
    } catch (_) {
      // A busy link (big transfer) can miss a beat; only give up after ~30 s.
      if (items.any((i) => i.active)) return;
      _misses++;
      if (_misses >= 3 && state.value == 'connected') state.value = 'reconnecting';
      if (_misses >= 10) await _end('Lost the connection to ${p.name}.');
    } finally {
      client.close(force: true);
    }
  }

  /// Ends the session on both sides.
  static Future<void> disconnect() async {
    final p = peer.value;
    final token = _token;
    if (p != null && token != null) {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      try {
        final req = await client.postUrl(Uri.http('${p.host}:${p.port}', '/session/close'));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({'token': token}));
        await (await req.close().timeout(const Duration(seconds: 3))).drain<void>();
      } catch (_) {
      } finally {
        client.close(force: true);
      }
    }
    await _end('Disconnected.');
  }

  static Future<void> _end(String reason) async {
    if (peer.value == null && !hostsHotspot && !joinedHotspot) return;
    debugPrint('[session] ended: $reason');
    _beat?.cancel();
    _beat = null;
    _token = null;
    _pairToken = null;
    endReason = reason;
    for (final it in items) {
      if (it.state == SessionItemState.queued) {
        it.state = SessionItemState.failed;
        it.detail = 'Not sent';
      }
    }
    _changed();
    peer.value = null;
    state.value = 'closed';
    _servedItem = null;
    PhoneHandoff.served.removeListener(_onServed);
    if (hostsHotspot) {
      hostsHotspot = false;
      await PhoneHandoff.stop();
      await HotspotShare.stop();
    }
    if (joinedHotspot) {
      joinedHotspot = false;
      await HotspotShare.leave();
    }
  }

  // ------------------------------------------------------------ transfers

  /// Queues files for the peer; they go one after another.
  static void enqueue(List<File> files) {
    for (final f in files) {
      if (!f.existsSync()) continue;
      items.add(SessionItem(outgoing: true, name: p.basename(f.path), size: f.lengthSync(), file: f));
    }
    _changed();
    unawaited(_pump());
  }

  static void remove(SessionItem it) {
    if (it.active) return;
    items.remove(it);
    _changed();
  }

  static Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        final p = peer.value;
        if (p == null) return;
        final next = items.where((i) => i.outgoing && i.state == SessionItemState.queued).firstOrNull;
        if (next == null) return;
        next.state = SessionItemState.sending;
        next.detail = 'Starting…';
        _changed();
        final meter = TransferMeter();
        String? error;
        // The other side receives one file at a time; wait while it is busy.
        for (var attempt = 0; attempt < 120; attempt++) {
          error = await NearbyService.sendTo(
            p.device,
            next.file!,
            onProgress: (sent, total) {
              if (!meter.update(sent, total)) return;
              next.done = sent;
              next.size = total;
              next.speed = meter.speed;
              next.detail = sent >= total && total > 0 ? 'Finishing…' : meter.label;
              _changed();
            },
          );
          if (error == null || !error.contains('busy') || peer.value == null) break;
          next.detail = 'Waiting — ${p.name} is receiving another file…';
          _changed();
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        if (error == null) {
          next.state = SessionItemState.done;
          next.done = next.size;
          next.detail = 'Sent · ${meter.doneLabel}';
          _heard();
        } else {
          next.state = SessionItemState.failed;
          next.detail = error;
        }
        _changed();
      }
    } finally {
      _pumping = false;
    }
  }

  static SessionItem? _incomingItem;
  static TransferMeter _incomingMeter = TransferMeter();

  static void _onIncoming() {
    final v = NearbyService.incoming.value;
    final p = peer.value;
    if (v == null || p == null || v.fromName != p.name) return;
    var it = _incomingItem;
    if (it == null || it.state != SessionItemState.receiving) {
      if (v.done) {
        // A finished event with no row: add it as one line.
        it = SessionItem(outgoing: false, name: v.fileName, size: v.total, state: SessionItemState.receiving);
        items.add(it);
      } else {
        it = SessionItem(outgoing: false, name: v.fileName, size: v.total, state: SessionItemState.receiving);
        items.add(it);
      }
      _incomingItem = it;
      _incomingMeter = TransferMeter();
    }
    _incomingMeter.update(v.received, v.total);
    it.speed = _incomingMeter.speed;
    it.name = v.fileName;
    it.size = v.total;
    it.done = v.received;
    it.detail = v.detail;
    if (v.done) {
      final saved = v.file != null || v.dir != null;
      it.state = saved ? SessionItemState.done : SessionItemState.failed;
      it.file = v.file;
      if (saved) {
        it.done = it.size;
        it.detail = 'Received${v.detail.isEmpty ? '' : ' · ${v.detail}'}';
      } else {
        it.detail = 'Stopped before the end';
      }
      _incomingItem = null;
    }
    _heard();
    _changed();
  }

  // The first file of a hotspot pairing goes over the handoff server; show it
  // in the list too.
  static SessionItem? _servedItem;
  static final TransferMeter _servedMeter = TransferMeter();

  static void trackServed(File file, String title) {
    final it = SessionItem(outgoing: true, name: p.basename(file.path), size: file.lengthSync(), file: file, state: SessionItemState.sending);
    it.done = min(PhoneHandoff.served.value, it.size);
    items.add(it);
    _servedItem = it;
    PhoneHandoff.served.addListener(_onServed);
    _onServed();
  }

  static void _onServed() {
    final it = _servedItem;
    if (it == null) return;
    it.done = min(PhoneHandoff.served.value, it.size);
    if (it.done >= it.size && it.size > 0) {
      it.state = SessionItemState.done;
      it.detail = 'Sent';
      _servedItem = null;
      PhoneHandoff.served.removeListener(_onServed);
    } else if (_servedMeter.update(it.done, it.size)) {
      it.speed = _servedMeter.speed;
      it.detail = it.done == 0 ? 'Waiting for ${peer.value?.name ?? 'the other device'}…' : _servedMeter.label;
    } else {
      return;
    }
    _changed();
  }
}
