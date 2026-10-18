import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, AppLifecycleState;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/library/session_keepalive.dart';
import 'package:path/path.dart' as p;
import 'package:social_save/features/library/hotspot_share.dart';
import 'package:social_save/features/library/nearby_service.dart';
import 'package:social_save/features/library/phone_handoff.dart';
import 'package:social_save/features/library/transfer_meter.dart';

/// The other device in a [ShareSession].
class SessionPeer {
  SessionPeer({
    required this.id,
    required this.name,
    required this.kind,
    required this.host,
    required this.port,
    required this.link,
    this.legacy = false,
    this.version,
    this.limited = false,
  });
  final String id;

  /// 1.0.36: this side found the other device (code / hotspot) but could not
  /// open a full session with it. It still shows the Connected screen, says
  /// why ([ShareSession.limitedReason]), and receives what the other side
  /// serves; "Try full connection" upgrades it.
  final bool limited;

  /// An older SocialSave (1.0.30 or earlier) that can't open a session: it
  /// only downloads what this device serves under the pairing code.
  final bool legacy;

  /// The other app's version (1.0.35+ report it; null = 1.0.34 or older).
  final String? version;

  /// True when the other app is older than this one (or doesn't say).
  bool get older => legacy || version == null || ShareSession.compareVersions(version!, AppConstants.appVersion) < 0;
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

  /// Automatic retries after a connection drop (the user can retry more).
  int autoRetries = 0;

  /// Received into the phone's gallery (videos and photos on Android).
  bool get inGallery => !outgoing && state == SessionItemState.done && file != null && Plat.isAndroid && _galleryName(file!.path);

  double? get fraction => size > 0 ? (done / size).clamp(0.0, 1.0) : null;
  bool get active => state == SessionItemState.sending || state == SessionItemState.receiving;
}

bool _galleryName(String path) {
  final e = p.extension(path).toLowerCase();
  return const {'.mp4', '.mkv', '.webm', '.mov', '.3gp', '.avi', '.m4v', '.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic'}.contains(e);
}

/// A file that arrived in an earlier (or this) session; kept across launches.
class ReceivedRecord {
  ReceivedRecord({required this.name, required this.path, required this.size, required this.at, required this.from});
  final String name;
  final String path;
  final int size;
  final DateTime at;
  final String from;

  bool get exists => FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
  bool get inGallery => Plat.isAndroid && _galleryName(path);

  Map<String, dynamic> toJson() => {'n': name, 'p': path, 's': size, 'a': at.millisecondsSinceEpoch, 'f': from};
  static ReceivedRecord? fromJson(Object? j) {
    if (j is! Map) return null;
    return ReceivedRecord(
      name: '${j['n'] ?? ''}',
      path: '${j['p'] ?? ''}',
      size: (j['s'] as num?)?.toInt() ?? 0,
      at: DateTime.fromMillisecondsSinceEpoch((j['a'] as num?)?.toInt() ?? 0),
      from: '${j['f'] ?? ''}',
    );
  }
}

/// Xender-style connection between two SocialSave apps.
///
/// After one pairing (hotspot QR, or "Connect" on a nearby device) both apps
/// keep each other as the session peer: either side can send files at any
/// time, the other side accepts them automatically, and a heartbeat watches
/// the link. Files still travel over the normal nearby inbox (`/ask` +
/// `/upload`), so nothing about saving changes.
///
/// 1.0.33: the session lives here (app level), never in a screen. It ends
/// only when someone presses Disconnect (in the app, on either device, or in
/// the notification). A dropped link shows "Reconnecting…" and is brought
/// back automatically (hotspot re-joined / re-opened, new address picked up);
/// only after [giveUpAfter] without any contact does it end by itself.
///
/// Wire protocol (on the nearby inbox port):
/// * `POST /session/open`  {id, name, kind, port, pair?, resume?} -> {ok, token, id, name, kind}
/// * `POST /session/ping`  {token, port} -> 200 while the session lives, 410 after
/// * `POST /session/close` {token}
class ShareSession {
  ShareSession._();

  static final ValueNotifier<SessionPeer?> peer = ValueNotifier<SessionPeer?>(null);

  /// 'connecting', 'connected', 'reconnecting' or 'closed'.
  static final ValueNotifier<String> state = ValueNotifier<String>('closed');

  /// Why the last session ended (shown on the session screen).
  static String endReason = '';

  /// The device of the last session (for "Reconnect").
  static SessionPeer? lastPeer;
  static bool _lastWasHotspotHost = false;

  /// Bumped whenever [items] change.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);
  static final List<SessionItem> items = [];

  /// Files received in any session (newest first), kept across launches.
  static final ValueNotifier<List<ReceivedRecord>> history = ValueNotifier<List<ReceivedRecord>>(const []);

  /// Asks the user whether [name] may connect. Set by the UI.
  static Future<bool> Function(String name, String kind)? onRequest;

  /// Called on this device when a session opens (to show the session screen).
  static void Function()? onOpened;

  /// While true, [onOpened] is not called (a dialog handles it itself).
  static int suppressAutoOpen = 0;

  /// Pairing UI that is open right now (QR / code dialogs, the Connect
  /// picker, the Receive sheet). Each entry closes its own route. All of
  /// them close the moment a session opens (Xender-style).
  static final Set<void Function()> pairingUi = {};

  /// A file picked before connecting (the QR / code dialog's file): it is
  /// sent as the first item of the session, so it shows in Transfers on both
  /// devices instead of a separate Watch/Save step.
  static File? pendingFirst;

  /// True while the session screen is visible.
  static final ValueNotifier<bool> screenVisible = ValueNotifier<bool>(false);
  static bool get screenOpen => screenVisible.value;
  static set screenOpen(bool v) => screenVisible.value = v;

  /// No contact at all for this long ends the session (after trying to
  /// reconnect the whole time).
  static Duration giveUpAfter = const Duration(minutes: 10);

  /// "Reconnecting…" shows after this long without contact.
  static Duration quietAfter = const Duration(seconds: 12);

  /// Test hooks turn this off so test runs never touch the saved session
  /// or the received history.
  static bool persist = true;

  static String? _token;
  static String? _pairToken;
  static bool hostsHotspot = false;
  static bool joinedHotspot = false;
  static Timer? _beat;
  static bool _pinging = false;
  static DateTime _lastHeard = DateTime.now();
  static DateTime _lastTouch = DateTime.fromMillisecondsSinceEpoch(0);
  static DateTime _lastRecover = DateTime.fromMillisecondsSinceEpoch(0);
  static Duration _giveUp = const Duration(minutes: 10);
  static bool _pumping = false;

  /// Stage 2: pause the send queue between files (the current file finishes).
  static final ValueNotifier<bool> paused = ValueNotifier<bool>(false);
  static void setPaused(bool value) {
    paused.value = value;
    if (!value) unawaited(_pump());
  }

  static bool _installed = false;
  static final Map<String, DateTime> _closedIds = {};

  static bool get active => peer.value != null;

  /// The Connected screen should open on Transfers (a file is on its way).
  static bool landOnTransfers = false;

  /// The QR link of the open pairing (hotspot / code), for "Show code".
  static String? pairLink;

  static int compareVersions(String a, String b) {
    List<int> parts(String v) => v.split('+').first.split('.').map((x) => int.tryParse(x) ?? 0).toList();
    final x = parts(a);
    final y = parts(b);
    for (var i = 0; i < max(x.length, y.length); i++) {
      final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
      if (d != 0) return d;
    }
    return 0;
  }

  // ------------------------------------------------ older SocialSave peers

  static bool _legacyCheck = false;
  static DateTime _lastServedAt = DateTime.now();

  /// Someone fetched the pairing offer (/info or /v). If no session follows
  /// within a few seconds it's an older SocialSave: open a "legacy" session
  /// anyway, so this side still lands on the Connected screen.
  static void _onContact(String host, bool download, bool joining) {
    _lastTouch = DateTime.now();
    final cur = peer.value;
    if (cur != null) {
      if (cur.legacy && cur.host != host) cur.host = host;
      return;
    }
    if (_legacyCheck) return;
    _legacyCheck = true;
    // 1.0.36 receivers say they'll open a session (joining): give that time
    // (hotspot links can take a while) before guessing "older app".
    Future<void>.delayed(Duration(seconds: joining ? 25 : 3), () {
      _legacyCheck = false;
      if (peer.value == null && PhoneHandoff.current != null) startLegacy(host);
    });
  }

  static void startLegacy(String host) {
    if (peer.value != null) return;
    final viaHotspot = hostsHotspotPending || hostsHotspot;
    if (viaHotspot) hostsHotspot = true;
    final peerInfo = SessionPeer(
      id: 'legacy:$host',
      name: viaHotspot ? 'Other phone' : 'Other device',
      kind: 'phone',
      host: host,
      port: 0,
      link: viaHotspot ? 'hotspot' : 'wifi',
      legacy: true,
    );
    _token = null;
    // The pairing token stays valid: a newer app that is just slow to open
    // its session still gets in (and this leaves legacy mode).
    _beat?.cancel();
    _beat = null;
    items.clear();
    peer.value = peerInfo;
    lastPeer = peerInfo;
    _lastWasHotspotHost = viaHotspot;
    state.value = 'connected';
    endReason = '';
    pendingFirst = null;
    final f = PhoneHandoff.currentFile;
    if (f != null && f.existsSync()) {
      landOnTransfers = true;
      trackServed(f, p.basenameWithoutExtension(f.path));
    }
    _changed();
    debugPrint('[session] older SocialSave at $host: legacy session (served file: ${f?.path})');
    unawaited(SessionKeepAlive.start(_title(), _text()));
    _updateNotification();
    onOpened?.call();
  }

  /// Added to the pairing server's /info: whoever found this offer by its
  /// code can open a session with it (no prompt: the code is the secret).
  static Map<String, dynamic>? _sessionInfo() {
    final cur = peer.value;
    if (cur != null && !cur.legacy) return null;
    if (NearbyService.id.isEmpty) return null;
    _pairToken ??= _newToken();
    return {
      'sid': _pairToken,
      'sp': NearbyService.inboxBoundPort,
      'sf': 1,
      'v': AppConstants.appVersion,
      'dn': NearbyService.name,
      'dk': NearbyService.kind,
    };
  }

  // ------------------------------------------- limited session (joiner)

  /// Why the session is limited (shown on the Connected screen).
  static String? limitedReason;
  static HandoffTarget? _limitedTarget;
  static Timer? _limitedPoll;
  static bool _limitedPolling = false;
  static int _limitedMisses = 0;
  static String _limitedSeen = '';

  static bool get isLimited => peer.value?.limited == true;

  /// Lands on the Connected screen even though no full session opened.
  static void startLimited(HandoffTarget t, String reason, {required String link}) {
    if (peer.value != null) return;
    final pr = SessionPeer(
      id: 'limited:${t.host}',
      name: t.senderName ?? (t.senderKind == 'pc' ? 'PC' : 'Other device'),
      kind: t.senderKind ?? 'phone',
      host: t.host,
      port: t.sp ?? NearbyService.inboxPort,
      link: link,
      version: t.version,
      limited: true,
    );
    _token = null;
    _beat?.cancel();
    _beat = null;
    items.clear();
    limitedReason = reason;
    _limitedTarget = t;
    _limitedMisses = 0;
    _limitedSeen = '';
    peer.value = pr;
    lastPeer = pr;
    _lastWasHotspotHost = false;
    state.value = 'connected';
    endReason = '';
    pendingFirst = null;
    landOnTransfers = t.hasFile;
    _changed();
    debugPrint('[session] limited session with ${t.host}:${t.port} ($reason)');
    unawaited(SessionKeepAlive.start(_title(), _text()));
    _updateNotification();
    onOpened?.call();
    _limitedPoll?.cancel();
    _limitedPoll = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_pollLimited()));
    unawaited(_pollLimited());
  }

  /// A full session opened, but the sender serves its first file instead
  /// of pushing it (older sender): fetch it into Transfers.
  static void receiveOffered(HandoffTarget t) {
    final pr = peer.value;
    if (pr == null || !t.hasFile) return;
    landOnTransfers = true;
    unawaited(_downloadOffered(t, pr));
  }

  static Future<void> _pollLimited() async {
    final t = _limitedTarget;
    final pr = peer.value;
    if (t == null || pr == null || !pr.limited) {
      _limitedPoll?.cancel();
      _limitedPoll = null;
      return;
    }
    if (_limitedPolling) return;
    _limitedPolling = true;
    try {
      final now = await PhoneHandoff.probe(t.host, t.port, t.code);
      if (peer.value != pr) return;
      if (now == null) {
        _limitedMisses++;
        if (_limitedMisses == 8 && state.value == 'connected') {
          state.value = 'reconnecting';
          _updateNotification();
        }
        if (_limitedMisses > 300) {
          await _end('Lost the connection to ${pr.name}. Receive the code again to reconnect.');
        }
        return;
      }
      _limitedMisses = 0;
      if (state.value == 'reconnecting') {
        state.value = 'connected';
        _updateNotification();
      }
      _limitedTarget = HandoffTarget(
        host: t.host,
        port: t.port,
        code: t.code,
        fileName: now.fileName,
        title: now.title,
        size: now.size,
        sid: now.sid ?? t.sid,
        sp: now.sp ?? t.sp,
        sendsInSession: now.sendsInSession,
        version: now.version ?? t.version,
        senderName: now.senderName ?? t.senderName,
        senderKind: now.senderKind ?? t.senderKind,
      );
      if (!now.hasFile) return;
      final sig = '${now.fileName}|${now.size}';
      if (sig == _limitedSeen) return;
      if (items.any((i) => !i.outgoing && i.state == SessionItemState.receiving)) return;
      _limitedSeen = sig;
      await _downloadOffered(now, pr);
    } finally {
      _limitedPolling = false;
    }
  }

  static Future<void> _downloadOffered(HandoffTarget t, SessionPeer from) async {
    final it = SessionItem(outgoing: false, name: t.fileName, size: t.size, state: SessionItemState.receiving);
    it.detail = 'Starting…';
    items.add(it);
    _changed();
    final meter = TransferMeter();
    File? file;
    try {
      file = await PhoneHandoff.download(t, onProgress: (r, total) {
        _lastTouch = DateTime.now();
        if (!meter.update(r, total)) return;
        it.done = r;
        it.size = total;
        it.speed = meter.speed;
        it.detail = meter.label;
        _changed();
      });
    } catch (e) {
      debugPrint('[session] download of ${t.fileName} failed: $e');
    }
    it.speed = 0;
    if (file != null) {
      it.state = SessionItemState.done;
      it.file = file;
      it.done = it.size;
      it.detail = 'Received · ${meter.doneLabel}';
      _remember(ReceivedRecord(name: t.fileName, path: file.path, size: it.size, at: DateTime.now(), from: from.name));
      final fg = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      if (!fg) unawaited(SessionKeepAlive.received('Received from ${from.name}', t.fileName));
    } else {
      it.state = SessionItemState.failed;
      it.detail = 'Stopped before the end';
    }
    _changed();
  }

  /// "Try full connection" on a limited session. Null on success.
  static Future<String?> upgradeLimited() async {
    final pr = peer.value;
    final t = _limitedTarget;
    if (pr == null || !pr.limited || t == null) return null;
    final fresh = await PhoneHandoff.probe(t.host, t.port, t.code, joining: true);
    final sid = fresh?.sid ?? t.sid;
    final sp = fresh?.sp ?? t.sp;
    if (sp == null) {
      return '${pr.name} has an older SocialSave. Update it to connect fully.';
    }
    final keep = List<SessionItem>.of(items);
    _limitedPoll?.cancel();
    _limitedPoll = null;
    peer.value = null;
    String? err;
    for (var i = 0; i < 3; i++) {
      err = await connect(host: t.host, port: sp, pair: sid, link: pr.link);
      if (err == null || peer.value != null) break;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (peer.value != null && !peer.value!.limited) {
      limitedReason = null;
      _limitedTarget = null;
      items.insertAll(0, keep.where((i) => !items.contains(i)));
      _changed();
      return null;
    }
    // Still limited: put it back as it was.
    peer.value = pr;
    state.value = 'connected';
    limitedReason = '${err ?? 'Could not connect.'} Files from ${pr.name} still arrive here.';
    _changed();
    _limitedPoll = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_pollLimited()));
    return err ?? 'Could not connect.';
  }

  /// Limited session: try the other device's inbox directly (it may ask
  /// its user to accept); say clearly when it can't be reached.
  static Future<void> _sendLimited(SessionPeer to, SessionItem next) async {
    next.state = SessionItemState.sending;
    next.detail = 'Starting…';
    _changed();
    final meter = TransferMeter();
    final error = await NearbyService.sendTo(
      to.device,
      next.file!,
      onProgress: (sent, total) {
        if (!meter.update(sent, total)) return;
        next.done = sent;
        next.size = total;
        next.speed = meter.speed;
        next.detail = meter.label;
        _changed();
      },
    );
    next.speed = 0;
    if (error == null) {
      next.state = SessionItemState.done;
      next.done = next.size;
      next.detail = 'Sent · ${meter.doneLabel}';
      _batchDone++;
    } else {
      next.state = SessionItemState.failed;
      next.detail = 'Not sent: $error Tap "Reconnect" above, then tap Retry.';
    }
    _changed();
  }

  static String legacyCode() {
    final c = PhoneHandoff.current?.code ?? '';
    return c.length == 6 ? '${c.substring(0, 3)} ${c.substring(3)}' : c;
  }

  static String _legacyWaiting(SessionPeer to) =>
      'Ready · on ${to.name}: SocialSave › Receive › scan the code again (Show code) or type ${legacyCode()}';

  static void install() {
    if (_installed) return;
    _installed = true;
    NearbyService.autoAccept = (fromId) => peer.value != null && peer.value!.id == fromId;
    NearbyService.extraRoute = _route;
    NearbyService.incoming.addListener(_onIncoming);
    PhoneHandoff.onContact = _onContact;
    PhoneHandoff.sessionInfo = _sessionInfo;
    PhoneHandoff.keepAlive = () => active;
    SessionKeepAlive.onDisconnect = disconnect;
    SessionKeepAlive.wire();
    HotspotShare.event.addListener(_onHotspotEvent);
    unawaited(_loadHistory());
    unawaited(_restore());
  }

  static void _changed() {
    revision.value++;
    _updateNotification();
  }

  static String _newToken() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  /// A one-time token for a QR pairing: whoever brings it back connects
  /// without a prompt.
  static String armPairing() => _pairToken = _newToken();

  /// Something is moving on the link (e.g. the first hotspot file being
  /// downloaded outside the session list): count it as contact.
  static void touch() {
    _lastTouch = DateTime.now();
    _heard();
  }

  static bool get transferActive =>
      items.any((i) => i.active) || DateTime.now().difference(_lastTouch) < const Duration(seconds: 10);

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
        if (ok) {
          _learnRoute(req, body);
          _heard();
        }
      case 'close':
        final ok = _token != null && body['token'] == _token;
        res.write(jsonEncode({'ok': ok}));
        if (ok) {
          final name = peer.value?.name ?? 'The other device';
          unawaited(Future<void>.delayed(Duration.zero, () => _end('$name disconnected.', explicit: true)));
        }
      default:
        res.statusCode = HttpStatus.notFound;
    }
    await res.close();
    return true;
  }

  /// A ping tells us where the other device is now (its address can change
  /// after a Wi-Fi drop, its inbox port after a restart).
  static void _learnRoute(HttpRequest req, Map<String, dynamic> body) {
    final pr = peer.value;
    if (pr == null || pr.link == 'usb') return;
    final from = req.connectionInfo?.remoteAddress;
    final port = (body['port'] as num?)?.toInt();
    var moved = false;
    if (from != null && !from.isLoopback && from.address != pr.host) {
      pr.host = from.address;
      moved = true;
    }
    if (port != null && port > 0 && port != pr.port) {
      pr.port = port;
      moved = true;
    }
    if (moved) {
      debugPrint('[session] ${pr.name} is now at ${pr.host}:${pr.port}');
      unawaited(_save());
    }
  }

  static Future<void> _handleOpen(HttpRequest req, Map<String, dynamic> body) async {
    final res = req.response;
    final id = '${body['id'] ?? ''}';
    final name = '${body['name'] ?? 'Another device'}';
    final kind = '${body['kind'] ?? 'phone'}';
    final port = (body['port'] as num?)?.toInt() ?? NearbyService.inboxPort;
    final pair = body['pair'] as String?;
    final resume = body['resume'] == true;
    if (id.isEmpty) {
      res.statusCode = HttpStatus.badRequest;
      res.write(jsonEncode({'ok': false}));
      return;
    }
    var current = peer.value;
    if (current != null && current.legacy) {
      // We guessed "older app" but it does open sessions after all.
      debugPrint('[session] ${current.host} opened a real session; leaving legacy mode');
      peer.value = null;
      state.value = 'closed';
      current = null;
    }
    if (current != null && current.id != id) {
      res.write(jsonEncode({'ok': false, 'busy': true, 'with': current.name}));
      return;
    }
    var ok = current != null && current.id == id; // reconnect from the same device
    if (!ok && pair != null && pair == _pairToken) ok = true;
    if (!ok && resume) {
      // Silent resume after a drop: never after an explicit Disconnect, and
      // only for devices this one already trusts.
      final closedAt = _closedIds[id];
      final recentlyClosed = closedAt != null && DateTime.now().difference(closedAt) < const Duration(minutes: 30);
      if (!recentlyClosed && await NearbyService.isTrusted(id)) ok = true;
      if (!ok) {
        res.write(jsonEncode({'ok': false, 'closed': recentlyClosed}));
        return;
      }
    }
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
    var link = (pair != null && pair == _pairToken && hostsHotspotPending) || (current?.link == 'hotspot') ? 'hotspot' : 'wifi';
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
    _closedIds.remove(id);
    final token = current != null ? _token! : _newToken();
    _start(SessionPeer(id: id, name: name, kind: kind, host: host, port: toPort, link: link, version: body['v'] as String?), token);
    res.write(jsonEncode({
      'ok': true,
      'token': token,
      'id': NearbyService.id,
      'name': NearbyService.name,
      'kind': NearbyService.kind,
      'v': AppConstants.appVersion,
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
    bool resume = false,
  }) async {
    final wasClosed = peer.value == null;
    if (wasClosed) state.value = 'connecting';
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.postUrl(Uri.http('$host:$port', '/session/open'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'id': NearbyService.id,
        'name': NearbyService.name,
        'kind': NearbyService.kind,
        'port': NearbyService.inboxBoundPort,
        'v': AppConstants.appVersion,
        if (pair != null) 'pair': pair,
        if (resume) 'resume': true,
      }));
      final res = await req.close().timeout(const Duration(seconds: 75));
      final text = await utf8.decoder.bind(res).join();
      if (res.statusCode == HttpStatus.notFound) {
        return 'Update SocialSave on the other device to 1.0.31 or newer to stay connected.';
      }
      final j = jsonDecode(text) as Map<String, dynamic>;
      if (j['ok'] != true) {
        if (j['busy'] == true) return 'The other device is already connected to ${j['with'] ?? 'another device'}.';
        if (j['closed'] == true) return 'The other device disconnected.';
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
          version: j['v'] as String?,
        ),
        '${j['token']}',
      );
      return null;
    } on TimeoutException {
      return 'The other device did not answer.';
    } catch (e) {
      debugPrint('[session] open $host:$port failed: $e');
      return 'Could not reach the other device.';
    } finally {
      client.close(force: true);
      if (wasClosed && peer.value == null && state.value == 'connecting') state.value = 'closed';
    }
  }

  /// "Reconnect" after the session ended: same device, same way if possible.
  /// Returns null on success, otherwise a short reason.
  static Future<String?> reconnect() async {
    final last = lastPeer;
    if (last == null) return 'Nothing to reconnect to.';
    if (peer.value != null) return null;
    if (last.link == 'hotspot') {
      if (_lastWasHotspotHost) return 'Start Fast share again and let ${last.name} scan the new code.';
      state.value = 'connecting';
      if (!await HotspotShare.rejoin()) {
        state.value = 'closed';
        return 'Could not join ${last.name}\'s hotspot again. Scan its code again.';
      }
      joinedHotspot = true;
      String? err;
      for (var i = 0; i < 4; i++) {
        err = await connect(host: last.host, port: last.port, link: 'hotspot', resume: true);
        if (err == null || err.contains('disconnected') || err.contains('accept')) break;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (err != null) {
        joinedHotspot = false;
        await HotspotShare.leave();
      }
      return err;
    }
    // Wi-Fi / cable: use the newest address we heard for that device.
    final seen = NearbyService.devices.value.where((d) => d.id == last.id).toList()..sort((a, b) => b.rank.compareTo(a.rank));
    if (seen.isNotEmpty) return connect(host: seen.first.host, port: seen.first.port, link: seen.first.link);
    return connect(host: last.host, port: last.port, link: last.link);
  }

  // ------------------------------------------------------------- session

  static void _start(SessionPeer p, String token, {bool restored = false}) {
    final fresh = peer.value == null;
    _token = token;
    peer.value = p;
    lastPeer = p;
    _lastWasHotspotHost = hostsHotspot && p.link == 'hotspot';
    state.value = restored ? 'reconnecting' : 'connected';
    endReason = '';
    _lastHeard = DateTime.now();
    _giveUp = restored ? const Duration(minutes: 3) : giveUpAfter;
    if (fresh) {
      items.clear();
      _changed();
    }
    _beat?.cancel();
    _beat = Timer.periodic(const Duration(seconds: 3), (_) => unawaited(_tick()));
    debugPrint('[session] ${restored ? 'restored' : 'connected'} ${p.name} ${p.host}:${p.port} via ${p.link}');
    unawaited(_save());
    if (fresh) unawaited(SessionKeepAlive.start(_title(), _text()));
    _updateNotification();
    if (fresh && !restored) {
      final first = pendingFirst;
      pendingFirst = null;
      if (first != null && first.existsSync()) {
        landOnTransfers = true;
        if (PhoneHandoff.current != null) {
          // 1.0.33 and older fetch the picked file from the pairing server
          // after connecting; 1.0.34+ wait for it in the session. Watch which
          // one this is for a moment so it never arrives twice.
          final seen = PhoneHandoff.contacts;
          final item = SessionItem(outgoing: true, name: first.path.split(RegExp(r'[\\/]')).last, size: first.lengthSync(), file: first);
          item.detail = 'Starting…';
          item.state = SessionItemState.sending; // placeholder; the pump skips it
          items.add(item);
          _changed();
          Future<void>.delayed(const Duration(seconds: 3), () {
            if (peer.value != p) {
              items.remove(item);
              return;
            }
            if (PhoneHandoff.contacts > seen || PhoneHandoff.served.value > 0) {
              debugPrint('[session] ${p.name} fetches the first file from the pairing server');
              items.remove(item);
              trackServed(first, p.name);
              _changed();
            } else {
              // Same row, now really queued: it stays the first transfer.
              final idle = !items.any((i) => i.outgoing && (i.state == SessionItemState.queued || i.state == SessionItemState.sending) && i != item);
              if (idle) {
                _batchTotal = 0;
                _batchDone = 0;
              }
              _batchTotal++;
              item.state = SessionItemState.queued;
              item.detail = '';
              _changed();
              unawaited(_pump());
            }
          });
        } else {
          // Give the other side a moment to finish opening its end, so the
          // file isn't offered before it knows this session (no prompt).
          _holdUntil = DateTime.now().add(const Duration(milliseconds: 1500));
          enqueue([first]);
        }
      }
      // 1.0.34: always land on the Connected screen (closes pairing UI).
      onOpened?.call();
    }
  }

  static void _heard() {
    _lastHeard = DateTime.now();
    if (state.value == 'reconnecting' && peer.value != null) {
      state.value = 'connected';
      _giveUp = giveUpAfter;
      debugPrint('[session] link back');
      _updateNotification();
      unawaited(_pump());
    }
  }

  static Future<void> _tick() async {
    if (_pinging || peer.value == null) return;
    _pinging = true;
    try {
      final r = await _ping();
      if (peer.value == null) return;
      if (r == 200) {
        _heard();
        return;
      }
      if (r == HttpStatus.gone) {
        // They no longer know this session (restarted, or it ended there).
        final p = peer.value!;
        final err = await connect(host: p.host, port: p.port, link: p.link, resume: true);
        if (err == null) {
          debugPrint('[session] resumed with ${p.name}');
          return;
        }
        await _end('${p.name} ended the connection.');
        return;
      }
      // No answer. A busy link (big transfer) can miss beats: that's fine.
      if (transferActive) return;
      final quiet = DateTime.now().difference(_lastHeard);
      if (quiet > quietAfter && state.value == 'connected') {
        state.value = 'reconnecting';
        debugPrint('[session] no answer for ${quiet.inSeconds}s: reconnecting');
        _updateNotification();
      }
      if (state.value == 'reconnecting') unawaited(_recover());
      if (quiet > _giveUp) {
        await _end('Lost the connection to ${peer.value?.name ?? 'the other device'}. Tap Reconnect to try again.');
      }
    } finally {
      _pinging = false;
    }
  }

  /// Returns the HTTP status of a ping, or 0 when nobody answered.
  static Future<int> _ping() async {
    final p = peer.value;
    final token = _token;
    if (p == null || token == null) return 0;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client.postUrl(Uri.http('${p.host}:${p.port}', '/session/ping'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'token': token, 'port': NearbyService.inboxBoundPort}));
      final res = await req.close().timeout(const Duration(seconds: 8));
      await res.drain<void>();
      return res.statusCode;
    } catch (_) {
      return 0;
    } finally {
      client.close(force: true);
    }
  }

  /// Tries to bring the link back while "Reconnecting…".
  static Future<void> _recover() async {
    final p = peer.value;
    if (p == null) return;
    final now = DateTime.now();
    if (now.difference(_lastRecover) < const Duration(seconds: 15)) return;
    _lastRecover = now;
    // A new address for the same device (Wi-Fi drop, DHCP)?
    final seen = NearbyService.devices.value.where((d) => d.id == p.id && d.host != p.host).toList()
      ..sort((a, b) => b.rank.compareTo(a.rank));
    if (seen.isNotEmpty && p.link != 'hotspot') {
      debugPrint('[session] trying ${p.name} at ${seen.first.host}:${seen.first.port}');
      p.host = seen.first.host;
      p.port = seen.first.port;
    }
    if (joinedHotspot && !HotspotShare.joinedLinkUp.value) {
      debugPrint('[session] re-joining the hotspot');
      await HotspotShare.rejoin();
    }
    if (hostsHotspot && !await HotspotShare.isRunning()) {
      debugPrint('[session] re-opening the hotspot');
      await HotspotShare.reopen();
    }
  }

  static void _onHotspotEvent() {
    final e = HotspotShare.event.value ?? '';
    if (peer.value == null) return;
    if (e.startsWith('stopped') && hostsHotspot) {
      debugPrint('[session] hotspot stopped by the phone; re-opening');
      _lastRecover = DateTime.fromMillisecondsSinceEpoch(0);
      unawaited(Future<void>.delayed(const Duration(seconds: 2), _recover));
    }
    if (e.startsWith('available') && joinedHotspot) _heard();
  }

  /// Ends the session on both sides (the Disconnect button / notification).
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
    await _end('Disconnected.', explicit: true);
  }

  static Future<void> _end(String reason, {bool explicit = false}) async {
    if (peer.value == null && !hostsHotspot && !joinedHotspot) return;
    debugPrint('[session] ended: $reason');
    final p = peer.value;
    if (explicit && p != null) _closedIds[p.id] = DateTime.now();
    _beat?.cancel();
    _beat = null;
    _token = null;
    _pairToken = null;
    _limitedPoll?.cancel();
    _limitedPoll = null;
    _limitedTarget = null;
    limitedReason = null;
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
    unawaited(_clearSaved());
    await SessionKeepAlive.stop();
    if (hostsHotspot) {
      hostsHotspot = false;
      await PhoneHandoff.stop();
      await HotspotShare.stop();
    } else if (PhoneHandoff.current != null) {
      // The pairing server stayed up for the session (older apps fetch
      // from it): it goes with the session.
      await PhoneHandoff.stop();
    }
    pairLink = null;
    if (joinedHotspot) {
      joinedHotspot = false;
      await HotspotShare.leave();
    }
  }

  // --------------------------------------------------- notification text

  static int _batchTotal = 0;
  static int _batchDone = 0;

  /// Status lines for the notification (Android) and the tray tooltip (Windows).
  static String get statusTitle => _title();
  static String get statusText => _text();

  static String _title() {
    final p = peer.value;
    if (p == null) return 'SocialSave';
    return state.value == 'reconnecting' ? 'Reconnecting to ${p.name}…' : 'Connected to ${p.name}';
  }

  static String _speed(double bps) => bps > 0 ? ' · ${(bps / (1024 * 1024)).toStringAsFixed(1)} MB/s' : '';

  static String _text() {
    final p = peer.value;
    if (p == null) return '';
    if (state.value == 'reconnecting') return 'Trying to reach ${p.name}. Keep Wi-Fi on.';
    final sending = items.where((i) => i.outgoing && i.state == SessionItemState.sending).firstOrNull;
    final receiving = items.where((i) => !i.outgoing && i.state == SessionItemState.receiving).firstOrNull;
    final parts = <String>[];
    if (sending != null) {
      parts.add('Sending ${min(_batchDone + 1, max(_batchTotal, 1))} of ${max(_batchTotal, 1)}${_speed(sending.speed)}');
    }
    if (receiving != null) parts.add('Receiving ${receiving.name}${_speed(receiving.speed)}');
    final band = HotspotShare.liveBandLabel.value;
    if (parts.isEmpty) return '${p.linkLabel}${band == null ? '' : ' · $band'} · Tap to send videos and files';
    return parts.join(' · ');
  }

  static void _updateNotification() {
    if (peer.value == null) return;
    SessionKeepAlive.update(_title(), _text());
  }

  // -------------------------------------------------------- persistence

  static const _savedKey = 'share_session_live';
  static const _historyKey = 'share_session_received';

  static Future<void> _save() async {
    if (!persist) return;
    final p = peer.value;
    final token = _token;
    if (p == null || token == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_savedKey, jsonEncode({
        'id': p.id,
        'name': p.name,
        'kind': p.kind,
        'host': p.host,
        'port': p.port,
        'link': p.link,
        'token': token,
        'at': DateTime.now().millisecondsSinceEpoch,
      }));
    } catch (_) {}
  }

  static Future<void> _clearSaved() async {
    if (!persist) return;
    try {
      (await SharedPreferences.getInstance()).remove(_savedKey);
    } catch (_) {}
  }

  /// The app was closed while connected (Wi-Fi / cable): pick the session
  /// up again; the other device still has it while it is reconnecting.
  static Future<void> _restore() async {
    if (!persist) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_savedKey);
      if (raw == null || peer.value != null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final at = DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0);
      final link = '${j['link']}';
      if (link == 'hotspot' || DateTime.now().difference(at) > const Duration(minutes: 30)) {
        await prefs.remove(_savedKey);
        return;
      }
      // Wait for the inbox (it answers the other side's pings).
      for (var i = 0; i < 20 && NearbyService.id.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      if (peer.value != null) return;
      _start(
        SessionPeer(
          id: '${j['id']}',
          name: '${j['name']}',
          kind: '${j['kind']}',
          host: '${j['host']}',
          port: (j['port'] as num?)?.toInt() ?? NearbyService.inboxPort,
          link: link,
        ),
        '${j['token']}',
        restored: true,
      );
    } catch (_) {}
  }

  static Future<void> _loadHistory() async {
    if (!persist) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = (jsonDecode(prefs.getString(_historyKey) ?? '[]') as List).map(ReceivedRecord.fromJson).whereType<ReceivedRecord>().toList();
      history.value = list;
    } catch (_) {}
  }

  static void _remember(ReceivedRecord r) {
    final list = [r, ...history.value.where((x) => x.path != r.path)];
    if (list.length > 200) list.removeRange(200, list.length);
    history.value = list;
    if (!persist) return;
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_historyKey, jsonEncode([for (final x in list) x.toJson()]));
      } catch (_) {}
    }());
  }

  static Future<void> clearHistory() async {
    history.value = const [];
    try {
      (await SharedPreferences.getInstance()).remove(_historyKey);
    } catch (_) {}
  }

  // ------------------------------------------------------------ transfers

  /// Queues files for the peer; they go one after another.
  static void enqueue(List<File> files) {
    final idle = !items.any((i) => i.outgoing && (i.state == SessionItemState.queued || i.state == SessionItemState.sending));
    if (idle) {
      _batchTotal = 0;
      _batchDone = 0;
    }
    for (final f in files) {
      if (!f.existsSync()) continue;
      items.add(SessionItem(outgoing: true, name: p.basename(f.path), size: f.lengthSync(), file: f));
      _batchTotal++;
    }
    _changed();
    unawaited(_pump());
  }

  /// Sends a failed item again.
  static void retry(SessionItem it) {
    if (!it.outgoing || it.state != SessionItemState.failed || it.file == null || !it.file!.existsSync()) return;
    final idle = !items.any((i) => i.outgoing && (i.state == SessionItemState.queued || i.state == SessionItemState.sending));
    if (idle) {
      _batchTotal = 0;
      _batchDone = 0;
    }
    _batchTotal++;
    it.state = SessionItemState.queued;
    it.done = 0;
    it.speed = 0;
    it.autoRetries = 0;
    it.detail = '';
    _changed();
    unawaited(_pump());
  }

  /// Retries every failed outgoing item.
  static void retryAll() {
    for (final it in items.where((i) => i.outgoing && i.state == SessionItemState.failed).toList()) {
      retry(it);
    }
  }

  static void remove(SessionItem it) {
    if (it.active) return;
    items.remove(it);
    _changed();
  }

  static DateTime _holdUntil = DateTime(2000);

  static Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (DateTime.now().isBefore(_holdUntil) && peer.value != null) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      while (true) {
        // Hold the queue while the link is being brought back.
        for (var w = 0; w < 600 && peer.value != null && state.value == 'reconnecting'; w++) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        final p = peer.value;
        if (p == null) return;
        final next = paused.value ? null : items.where((i) => i.outgoing && i.state == SessionItemState.queued).firstOrNull;
        if (next == null) return;
        if (p.limited) {
          await _sendLimited(p, next);
          continue;
        }
        if (p.legacy) {
          await _sendLegacy(p, next);
          continue;
        }
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
        next.speed = 0;
        if (error == null) {
          next.state = SessionItemState.done;
          next.done = next.size;
          next.detail = 'Sent · ${meter.doneLabel}';
          _batchDone++;
          _heard();
        } else if (peer.value != null && next.autoRetries < 3 && !error.contains('declined') && !error.contains('could not save')) {
          // The link dropped: wait for it and send this one again.
          next.autoRetries++;
          next.state = SessionItemState.queued;
          next.done = 0;
          next.detail = 'Waiting for the connection… (retry ${next.autoRetries} of 3)';
          debugPrint('[session] send failed ($error); retry ${next.autoRetries}');
          if (state.value == 'connected') {
            final r = await _ping();
            if (r != 200 && peer.value != null) {
              state.value = 'reconnecting';
              _lastHeard = DateTime.now().subtract(quietAfter);
            }
          }
          await Future<void>.delayed(const Duration(seconds: 2));
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

  /// Older SocialSave: serve [next] under the pairing code and wait until
  /// the other device has downloaded it (it receives again for each file).
  static Future<void> _sendLegacy(SessionPeer to, SessionItem next) async {
    // Let the file it is fetching right now finish first.
    while (peer.value == to && _servedItem != null && _servedItem!.state == SessionItemState.sending) {
      if (PhoneHandoff.served.value > 0 && DateTime.now().difference(_lastServedAt) > const Duration(seconds: 40)) {
        final stalled = _servedItem!;
        stalled.state = SessionItemState.failed;
        stalled.detail = 'Stopped before the end';
        _servedItem = null;
        PhoneHandoff.served.removeListener(_onServed);
        _changed();
        break;
      }
      if (PhoneHandoff.served.value == 0) break; // never started: replace it
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (peer.value != to || PhoneHandoff.current == null) return;
    final old = _servedItem;
    if (old != null && old.state == SessionItemState.sending) {
      old.state = SessionItemState.queued; // not fetched yet: after this one
      old.detail = '';
    }
    PhoneHandoff.served.removeListener(_onServed);
    PhoneHandoff.swap(next.file!);
    next.state = SessionItemState.sending;
    next.done = 0;
    _servedItem = next;
    _servedMeter = TransferMeter();
    _lastServedAt = DateTime.now();
    PhoneHandoff.served.addListener(_onServed);
    next.detail = _legacyWaiting(to);
    _changed();
    while (peer.value == to && next.state == SessionItemState.sending) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (next.state == SessionItemState.done) _batchDone++;
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
        final path = (v.dir ?? v.file!).path;
        _remember(ReceivedRecord(name: v.fileName, path: path, size: v.total, at: DateTime.now(), from: p.name));
        final fg = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
        if (!fg) unawaited(SessionKeepAlive.received('Received from ${p.name}', v.fileName));
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
  static TransferMeter _servedMeter = TransferMeter();

  static void trackServed(File file, String title) {
    final it = SessionItem(outgoing: true, name: p.basename(file.path), size: file.lengthSync(), file: file, state: SessionItemState.sending);
    it.done = min(PhoneHandoff.served.value, it.size);
    items.add(it);
    _servedItem = it;
    _servedMeter = TransferMeter();
    _lastServedAt = DateTime.now();
    PhoneHandoff.served.addListener(_onServed);
    _onServed();
  }

  static void _onServed() {
    final it = _servedItem;
    if (it == null) return;
    _lastTouch = DateTime.now();
    _lastServedAt = DateTime.now();
    it.done = min(PhoneHandoff.served.value, it.size);
    if (it.done >= it.size && it.size > 0) {
      it.state = SessionItemState.done;
      it.detail = 'Sent';
      _servedItem = null;
      PhoneHandoff.served.removeListener(_onServed);
    } else if (_servedMeter.update(it.done, it.size)) {
      it.speed = _servedMeter.speed;
      final to = peer.value;
      it.detail = it.done == 0
          ? (to != null && to.legacy ? _legacyWaiting(to) : 'Waiting for ${to?.name ?? 'the other device'}…')
          : _servedMeter.label;
    } else {
      return;
    }
    _changed();
  }
}
