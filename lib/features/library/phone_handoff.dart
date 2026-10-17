import 'dart:async';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/core/platform/media_events.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart';
import 'package:social_save/features/library/bundle_transfer.dart';
import 'package:social_save/features/library/bundle_ui.dart';
import 'package:social_save/features/library/firewall_check.dart';
import 'package:social_save/features/library/hotspot_guide.dart';
import 'package:social_save/features/library/hotspot_share.dart';
import 'package:social_save/features/library/pc_hotspot.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:social_save/features/library/nearby_service.dart';
import 'package:social_save/features/library/session_ui.dart';
import 'package:social_save/features/library/share_session.dart';
import 'package:social_save/features/library/transfer_boost.dart';
import 'package:social_save/features/library/transfer_meter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:social_save/shared/widgets/qr_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:social_save/core/platform/desktop_support.dart';
import 'package:social_save/core/platform/phone_body.dart';
import 'package:social_save/core/storage/download_path_service.dart';
import 'package:social_save/core/storage/media_store_service.dart';
import 'package:social_save/features/library/nearby_ui.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/routing/app_router.dart';
import 'package:social_save/features/home/presentation/providers/home_controller.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:social_save/web/web_pages.dart';

/// Sends one video to another SocialSave app (phone or PC) on the same Wi-Fi.
///
/// The sender runs a small HTTP server on [port]. Every request must carry
/// the session code. The receiver finds the sender either from the QR link,
/// or from the 6-character code: it broadcasts "who has CODE" over UDP and,
/// if nobody answers, tries the fixed port on every address of its own /24
/// network. The receiver can stream it (Watch) or keep a copy (Save).
/// The video never goes through the internet or the SocialSave server.
class PhoneHandoff {
  PhoneHandoff._();

  static const int port = 47321;
  static const int discoveryPort = 47322;
  static const Duration lifetime = Duration(minutes: 15);
  static const String _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  static HttpServer? _server;
  static RawDatagramSocket? _udp;
  static Timer? _timer;
  static HandoffOffer? current;

  /// Bytes the sender has served for the current offer (all requests).
  static final ValueNotifier<int> served = ValueNotifier<int>(0);

  /// The file behind the current offer (null: "lobby", nothing picked yet).
  static File? _file;

  /// A SocialSave APK served at /app/<code>/<name> (to update older phones
  /// through their browser).
  static File? apkFile;

  /// Number of download requests (GET /v) seen for the current offer.
  static int downloads = 0;

  /// /info or /v requests from other devices for the current offer.
  static int contacts = 0;

  static File? get currentFile => _file;

  /// Someone fetched /info or /v from [host] (download: true for /v). The
  /// session uses this to spot older SocialSave versions that never open a
  /// session, and still move on to the Connected screen.
  static void Function(String host, bool download, bool joining)? onContact;

  /// Session details added to /info (1.0.36): a device that found this offer
  /// by its code can open a lasting session from it, not only download.
  static Map<String, dynamic>? Function()? sessionInfo;

  /// While true the offer outlives [lifetime] (a session is using it).
  static bool Function()? keepAlive;

  /// Serves [file] next under the same code and address, so a device that
  /// can't open a session (older SocialSave) gets it by receiving again.
  static void swap(File file, {String? title}) {
    final o = current;
    if (o == null) return;
    _file = file;
    final name = p.basename(file.path);
    current = HandoffOffer(
      code: o.code,
      ips: o.ips,
      port: o.port,
      fileName: name,
      title: title ?? p.basenameWithoutExtension(name),
      size: file.lengthSync(),
    );
    served.value = 0;
  }

  static String? apkUrl() {
    final o = current;
    final f = apkFile;
    if (o == null || f == null) return null;
    return 'http://${o.ips.first}:${o.port}/app/${o.code}/${Uri.encodeComponent(p.basename(f.path))}';
  }

  /// [preferIp] goes first in the offer (the hotspot address for Fast share).
  /// A null [file] opens the offer with nothing in it yet (hotspot quick
  /// share): files are picked after connecting.
  static Future<HandoffOffer?> offer(File? file, {String? title, String? preferIp}) async {
    await stop();
    if (file != null && !file.existsSync()) return null;
    final ips = await lanIps();
    if (preferIp != null) {
      ips.remove(preferIp);
      ips.insert(0, preferIp);
    }
    if (ips.isEmpty) return null;
    served.value = 0;
    downloads = 0;
    contacts = 0;
    final code = newCode();
    HttpServer server;
    server = await _bindNear(port);
    _server = server;
    final name = file == null ? '' : p.basename(file.path);
    final offer = HandoffOffer(
      code: code,
      ips: ips,
      port: server.port,
      fileName: name,
      title: title ?? (file == null ? '' : p.basenameWithoutExtension(name)),
      size: file == null ? 0 : await file.length(),
    );
    current = offer;
    _file = file;
    _armTimer();
    unawaited(_serve(server));
    try {
      final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort, reuseAddress: true);
      udp.broadcastEnabled = true;
      _udp = udp;
      udp.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = udp.receive();
        if (dg == null) return;
        final text = String.fromCharCodes(dg.data).trim();
        if (text != 'SSWHO $code') return;
        udp.send('SSHERE $code ${server.port}'.codeUnits, dg.address, dg.port);
      });
    } catch (_) {
      // Port busy or blocked. The subnet sweep still finds us.
    }
    return offer;
  }

  /// Binds [first], else a spare port inside the firewall rule's range
  /// (47321-47330), else any port.
  static Future<HttpServer> _bindNear(int first) async {
    for (final n in [first, 47329, 47330]) {
      try {
        return await HttpServer.bind(InternetAddress.anyIPv4, n, shared: false);
      } catch (_) {}
    }
    return HttpServer.bind(InternetAddress.anyIPv4, 0);
  }

  static void _armTimer() {
    _timer?.cancel();
    _timer = Timer(lifetime, () {
      if (keepAlive?.call() == true) {
        _armTimer();
      } else {
        unawaited(stop());
      }
    });
  }

  static Future<void> _serve(HttpServer server) async {
    try {
      await for (final request in server) {
        final offer = current;
        if (offer == null) {
          try {
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
          } catch (_) {}
          continue;
        }
        unawaited(_handle(request, _file, offer));
      }
    } catch (_) {}
  }

  static Future<void> _serveApk(HttpRequest request, File apk) async {
    final res = request.response;
    final length = await apk.length();
    res.headers.contentType = ContentType('application', 'vnd.android.package-archive');
    res.headers.set('Content-Disposition', 'attachment; filename="${p.basename(apk.path)}"');
    res.headers.contentLength = length;
    if (request.method == 'HEAD') {
      await res.close();
      return;
    }
    await TransferBoost.begin();
    try {
      await res.addStream(TransferBoost.read(apk, 0, length));
    } finally {
      await TransferBoost.end();
    }
    await res.close();
  }

  static Future<void> _handle(HttpRequest request, File? file, HandoffOffer offer) async {
    final res = request.response;
    try {
      res.headers.set('Access-Control-Allow-Origin', '*');
      final parts = request.uri.pathSegments;
      final okCode = parts.length >= 2 && parts[1].toUpperCase() == offer.code;
      if (!okCode) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      final from = request.connectionInfo?.remoteAddress;
      if (parts[0] == 'app') {
        final apk = apkFile;
        if (apk == null || !apk.existsSync()) {
          res.statusCode = HttpStatus.notFound;
          await res.close();
          return;
        }
        await _serveApk(request, apk);
        return;
      }
      if (from != null && !from.isLoopback && (parts[0] == 'info' || parts[0] == 'v')) {
        if (parts[0] == 'v' && request.method == 'GET') downloads++;
        contacts++;
        onContact?.call(from.address, parts[0] == 'v', request.uri.queryParameters['s'] == '1');
      }
      if (parts[0] == 'info') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'app': 'socialsave',
          'role': 'sender',
          'code': offer.code,
          'name': offer.fileName,
          'title': offer.title,
          'size': offer.size,
          ...?sessionInfo?.call(),
        }));
        await res.close();
        return;
      }
      if (parts[0] != 'v' || (request.method != 'GET' && request.method != 'HEAD') || file == null) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      final length = await file.length();
      res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      res.headers.contentType = _mimeOf(file.path);
      var start = 0;
      var end = length - 1;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final match = range == null ? null : RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
      if (match != null) {
        final a = match.group(1) ?? '';
        final b = match.group(2) ?? '';
        if (a.isEmpty && b.isNotEmpty) {
          start = max(0, length - int.parse(b));
        } else {
          start = int.tryParse(a) ?? 0;
          if (b.isNotEmpty) end = min(length - 1, int.parse(b));
        }
        if (start >= length || start > end) {
          res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
          await res.close();
          return;
        }
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length');
      }
      res.headers.contentLength = end - start + 1;
      if (request.method == 'HEAD') {
        await res.close();
        return;
      }
      await TransferBoost.begin();
      try {
        await res.addStream(TransferBoost.read(file, start, end + 1).map((chunk) {
          served.value += chunk.length;
          return chunk;
        }));
      } finally {
        await TransferBoost.end();
      }
      await res.close();
    } catch (_) {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  static ContentType _mimeOf(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.mkv':
        return ContentType('video', 'x-matroska');
      case '.webm':
        return ContentType('video', 'webm');
      case '.mov':
        return ContentType('video', 'quicktime');
      case '.mp3':
        return ContentType('audio', 'mpeg');
      case '.m4a':
        return ContentType('audio', 'mp4');
      default:
        return ContentType('video', 'mp4');
    }
  }

  static Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    current = null;
    _file = null;
    _udp?.close();
    _udp = null;
    final server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
    }
  }

  /// Turns a scanned link, a typed link or a 6-character code into the
  /// sender's address. Returns null when nobody answers on this Wi-Fi.
  /// [joining]: this device will open a session right after (1.0.36), so
  /// the sender waits for it instead of treating it as an older app.
  static Future<HandoffTarget?> resolve(String raw, {bool joining = false}) async {
    final text = raw.trim();
    final uri = Uri.tryParse(text);
    if (uri != null && uri.scheme == 'http' && uri.host.isNotEmpty) {
      final segs = uri.pathSegments;
      if (segs.length >= 2 && segs[0] == 'v') {
        return _probe(uri.host, uri.port, segs[1].toUpperCase(), joining: joining);
      }
      return null;
    }
    final code = normalizeCode(text);
    if (code == null) return null;
    final viaUdp = await _discoverUdp(code, joining: joining);
    if (viaUdp != null) return viaUdp;
    return _sweep(code, joining: joining);
  }

  /// Asks [host] for the offer again (limited sessions poll it for the next
  /// file). Null when it doesn't answer.
  static Future<HandoffTarget?> probe(String host, int port, String code, {bool joining = false}) =>
      _probe(host, port, code, joining: joining, timeout: const Duration(seconds: 3));

  static String? normalizeCode(String text) {
    final code = text.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
    if (code.length != 6) return null;
    return code;
  }

  static Future<HandoffTarget?> _discoverUdp(String code, {String role = 'sender', bool joining = false}) async {
    RawDatagramSocket? udp;
    try {
      udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      udp.broadcastEnabled = true;
      final found = Completer<HandoffTarget?>();
      udp.listen((event) {
        if (event != RawSocketEvent.read || found.isCompleted) return;
        final dg = udp!.receive();
        if (dg == null) return;
        final parts = String.fromCharCodes(dg.data).trim().split(' ');
        if (parts.length == 3 && parts[0] == 'SSHERE' && parts[1] == code) {
          final port = int.tryParse(parts[2]);
          if (port == null) return;
          unawaited(_probe(dg.address.address, port, code, role: role, joining: joining).then((t) {
            if (t != null && !found.isCompleted) found.complete(t);
          }));
        }
      });
      final message = 'SSWHO $code'.codeUnits;
      final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
      for (final ip in await lanIps()) {
        final q = ip.split('.');
        targets.add(InternetAddress('${q[0]}.${q[1]}.${q[2]}.255'));
      }
      for (var i = 0; i < 4 && !found.isCompleted; i++) {
        for (final t in targets) {
          try {
            udp.send(message, t, discoveryPort);
          } catch (_) {}
        }
        await Future.any([found.future, Future<void>.delayed(const Duration(milliseconds: 600))]);
      }
      return found.isCompleted ? await found.future : null;
    } catch (_) {
      return null;
    } finally {
      udp?.close();
    }
  }

  static Future<HandoffTarget?> _sweep(String code, {int port = port, String role = 'sender', bool joining = false}) async {
    final own = await lanIps();
    final hosts = <String>[];
    for (final ip in own) {
      final q = ip.split('.');
      for (var i = 1; i < 255; i++) {
        hosts.add('${q[0]}.${q[1]}.${q[2]}.$i');
      }
    }
    final found = Completer<HandoffTarget?>();
    var pending = hosts.length;
    if (pending == 0) return null;
    // 32 at a time keeps the phone happy.
    var next = 0;
    Future<void> worker() async {
      while (next < hosts.length && !found.isCompleted) {
        final host = hosts[next++];
        final t = await _probe(host, port, code, role: role, joining: joining, timeout: const Duration(milliseconds: 900));
        pending--;
        if (t != null && !found.isCompleted) found.complete(t);
      }
    }
    final workers = [for (var i = 0; i < 32; i++) worker()];
    unawaited(Future.wait(workers).then((_) {
      if (!found.isCompleted) found.complete(null);
    }));
    return found.future;
  }

  static Future<HandoffTarget?> _probe(String host, int port, String code,
      {String role = 'sender', Duration timeout = const Duration(seconds: 4), bool joining = false}) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client
          .getUrl(Uri.http('$host:$port', '/info/$code', joining ? const {'s': '1'} : null))
          .timeout(timeout);
      final res = await req.close().timeout(timeout);
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final body = await res.transform(utf8.decoder).join().timeout(timeout);
      final json = jsonDecode(body) as Map<String, dynamic>;
      if (json['app'] != 'socialsave') return null;
      if ((json['role'] ?? 'sender') != role) return null;
      return HandoffTarget(
        host: host,
        port: port,
        code: code,
        fileName: json['name'] as String? ?? 'video.mp4',
        title: json['title'] as String? ?? 'Video',
        size: (json['size'] as num?)?.toInt() ?? 0,
        sid: json['sid'] as String?,
        sp: (json['sp'] as num?)?.toInt(),
        sendsInSession: json['sf'] == 1,
        version: json['v'] as String?,
        senderName: json['dn'] as String?,
        senderKind: json['dk'] as String?,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Saves a copy. Windows: Documents\SocialSave. Android: the usual
  /// Download/SocialSave folder, then published to the gallery.
  static Future<File?> download(HandoffTarget target,
      {void Function(int received, int total)? onProgress, CancelToken? cancel}) async {
    final dest = await _destFor(target.fileName);
    await TransferBoost.begin();
    try {
    await Dio().download(
      target.videoUrl,
      dest.path,
      cancelToken: cancel,
      onReceiveProgress: (r, t) => onProgress?.call(r, t > 0 ? t : target.size),
    );
    } finally {
      await TransferBoost.end();
    }
    if (!dest.existsSync() || await dest.length() < 32) return null;
    await _publish(dest);
    return dest;
  }

  static Future<File> destFor(String rawName) => _destFor(rawName);
  static Future<void> publish(File dest) => _publish(dest);

  static Future<File> _destFor(String rawName) async {
    final base = p.basename(rawName.replaceAll('\\', '/'));
    if (p.extension(base).isNotEmpty && !isVideoName(base)) {
      // Any other file type goes to the Received folder, never over a file.
      return destInside(await receivedRoot(), base);
    }
    final Directory folder;
    if (DesktopSupport.isWindows) {
      folder = Directory(p.join(Platform.environment['USERPROFILE'] ?? '.', 'Documents', 'SocialSave'));
      await folder.create(recursive: true);
    } else {
      folder = await DownloadPathService().resolveDirectory(DownloadLocation.publicDownloads);
    }
    var name = p.basename(rawName).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    if (name.trim().isEmpty) name = 'SocialSave-${DateTime.now().millisecondsSinceEpoch}.mp4';
    if (p.extension(name).isEmpty) name = '$name.mp4';
    var dest = File(p.join(folder.path, name));
    var i = 1;
    while (dest.existsSync()) {
      dest = File(p.join(folder.path, '${p.basenameWithoutExtension(name)} ($i)${p.extension(name)}'));
      i++;
    }
    return dest;
  }

  static Future<void> _publish(File dest) async {
    if (!isVideoName(dest.path)) {
      await indexReceived(dest);
      return;
    }
    if (!DesktopSupport.isWindows) {
      final path = dest.path.replaceFirst('/sdcard/', '/storage/emulated/0/');
      if (path.startsWith('/storage/emulated/0/Download/')) {
        // Already in public Downloads: index it instead of copying it again.
        await indexReceived(dest);
        return;
      }
      try {
        await MediaStoreService().publishToDownloads(
          sourcePath: dest.path,
          fileName: p.basename(dest.path),
          mimeType: _mimeOf(dest.path).mimeType,
        );
      } catch (_) {}
    } else {
      DesktopSupport.cachedVideos = null;
    }
  }

  // ---- Reverse direction: the receiver shows a code, the sender pushes. ----
  // Needed when the sender cannot accept connections (e.g. Windows firewall
  // without admin): only the receiver listens.

  static const int dropPort = 47323;
  static HttpServer? _dropServer;
  static RawDatagramSocket? _dropUdp;
  static final ValueNotifier<DropState?> drop = ValueNotifier<DropState?>(null);
  static final Map<String, Directory> _dropDirs = {};
  static String? _dropBundle;

  /// Starts listening and returns the code to show, or null without Wi-Fi.
  static Future<String?> openDrop() async {
    await closeDrop();
    final ips = await lanIps();
    if (ips.isEmpty) return null;
    final code = newCode();
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, dropPort);
    } catch (_) {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _dropServer = server;
    drop.value = null;
    unawaited(() async {
      try {
        await for (final req in server) {
          unawaited(_handleDrop(req, code));
        }
      } catch (_) {}
    }());
    try {
      final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort, reuseAddress: true);
      udp.broadcastEnabled = true;
      _dropUdp = udp;
      udp.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = udp.receive();
        if (dg == null) return;
        if (String.fromCharCodes(dg.data).trim() != 'SSWHO $code') return;
        udp.send('SSHERE $code ${server.port}'.codeUnits, dg.address, dg.port);
      });
    } catch (_) {}
    return code;
  }

  static Future<void> _handleDrop(HttpRequest req, String code) async {
    final res = req.response;
    try {
      final parts = req.uri.pathSegments;
      if (parts.length < 2 || parts[1].toUpperCase() != code) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      if (parts[0] == 'info') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'app': 'socialsave', 'role': 'receiver', 'code': code}));
        await res.close();
        return;
      }
      final bundleHdr = req.headers.value('x-bundle');
      final sameBundle = bundleHdr != null && bundleHdr == _dropBundle;
      if (parts[0] != 'drop' || req.method != 'POST' || (drop.value?.busy == true && !sameBundle)) {
        res.statusCode = parts[0] == 'drop' ? HttpStatus.conflict : HttpStatus.notFound;
        await res.close();
        return;
      }
      final name = Uri.decodeComponent(req.headers.value('x-name') ?? 'video.mp4');
      final title = Uri.decodeComponent(req.headers.value('x-title') ?? p.basenameWithoutExtension(name));
      final total = req.contentLength;
      final bundle = req.headers.value('x-bundle');
      final rel = Uri.decodeComponent(req.headers.value('x-rel') ?? name);
      File dest;
      final count = int.tryParse(req.headers.value('x-count') ?? '') ?? 1;
      final index = int.tryParse(req.headers.value('x-index') ?? '') ?? 0;
      final more = bundle != null && index < count - 1;
      _dropBundle = more ? bundle : null;
      if (bundle != null && bundle.isNotEmpty) {
        final key = Uri.decodeComponent(bundle);
        final dir = _dropDirs[key] ??= await newReceiveDir(key.split('\u0000').last);
        dest = await destInside(dir, rel);
      } else {
        dest = await _destFor(name);
      }
      drop.value = DropState(title: title, received: 0, total: total, busy: true);
      var got = 0;
      final meter = TransferMeter();
      await TransferBoost.begin();
      try {
        got = await writeStreamToFile(req, dest, onBytes: (n) {
          got = n;
          if (meter.update(n, total)) {
            drop.value = DropState(title: title, received: n, total: total, busy: true, detail: meter.label);
          }
        });
      } catch (_) {
        got = -1;
      } finally {
        await TransferBoost.end();
      }
      final ok = total >= 0 ? got == total : got > 32;
      if (!ok) {
        try {
          await dest.delete();
        } catch (_) {}
        drop.value = DropState(title: title, received: got, total: total, failed: true);
        res.statusCode = HttpStatus.badRequest;
        await res.close();
        return;
      }
      // Answer the sender first (it waits at 100% for this), then register
      // the file with the gallery in the background.
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({'ok': true, 'path': dest.path}));
      await res.close();
      unawaited(_publish(dest));
      drop.value = more
          ? DropState(title: '$title (${index + 1}/$count)', received: got, total: total, busy: true, detail: meter.doneLabel)
          : DropState(
              title: bundle != null ? '$count files' : title,
              received: got,
              total: total,
              file: bundle != null ? File(_dropDirs[Uri.decodeComponent(bundle)]!.path) : dest,
              detail: meter.doneLabel,
            );
    } catch (_) {
      drop.value = const DropState(title: 'Video', received: 0, total: 0, failed: true);
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  static Future<void> closeDrop() async {
    _dropUdp?.close();
    _dropUdp = null;
    final s = _dropServer;
    _dropServer = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
  }

  /// Sender side of the reverse direction: find the device showing [rawCode]
  /// and upload the file to it. Returns null on success, or a short reason.
  static Future<String?> push(File file, String rawCode, {String? title, void Function(int sent, int total)? onProgress}) async {
    final code = normalizeCode(rawCode);
    if (code == null) return 'The code has 6 letters or numbers.';
    final target = await _discoverUdp(code, role: 'receiver') ??
        await _sweep(code, port: dropPort, role: 'receiver');
    if (target == null) return 'Could not find that code on this Wi-Fi.';
    final total = await file.length();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    await TransferBoost.begin();
    try {
      final req = await client.postUrl(Uri.http('${target.host}:${target.port}', '/drop/$code'));
      req.headers.set('x-name', Uri.encodeComponent(p.basename(file.path)));
      req.headers.set('x-title', Uri.encodeComponent(title ?? p.basenameWithoutExtension(file.path)));
      req.headers.contentType = ContentType.binary;
      req.contentLength = total;
      var sent = 0;
      await req.addStream(TransferBoost.read(file).map((chunk) {
        sent += chunk.length;
        onProgress?.call(sent, total);
        return chunk;
      }));
      final res = await req.close().timeout(const Duration(minutes: 5));
      await res.drain<void>().timeout(const Duration(minutes: 1));
      if (res.statusCode == HttpStatus.conflict) return 'The other device is busy receiving.';
      return res.statusCode == 200 ? null : 'The other device could not save it.';
    } catch (_) {
      return 'The copy stopped. Stay on the same Wi-Fi and try again.';
    } finally {
      await TransferBoost.end();
      client.close(force: true);
    }
  }

  /// Sends several files / a folder to the device showing [rawCode], one
  /// upload per file (older receivers simply save each file).
  static Future<String?> pushBundle(SendBundle bundle, String rawCode,
      {void Function(int sent, int total, int index, String rel)? onProgress, ValueNotifier<bool>? cancel}) async {
    final code = normalizeCode(rawCode);
    if (code == null) return 'The code has 6 letters or numbers.';
    final target = await _discoverUdp(code, role: 'receiver') ??
        await _sweep(code, port: dropPort, role: 'receiver');
    if (target == null) return 'Could not find that code on this Wi-Fi.';
    final key = '${DateTime.now().millisecondsSinceEpoch}\u0000${bundle.label}';
    final total = bundle.total;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    void abort() => client.close(force: true);
    cancel?.addListener(abort);
    await TransferBoost.begin();
    var done = 0;
    try {
      for (var i = 0; i < bundle.items.length; i++) {
        if (cancel?.value == true) return 'Cancelled.';
        final it = bundle.items[i];
        final req = await client.postUrl(Uri.http('${target.host}:${target.port}', '/drop/$code'));
        req.headers.set('x-name', Uri.encodeComponent(p.basename(it.rel)));
        req.headers.set('x-title', Uri.encodeComponent(it.rel));
        if (bundle.isFolder || bundle.count > 1) {
          req.headers.set('x-bundle', Uri.encodeComponent(key));
          req.headers.set('x-rel', Uri.encodeComponent(bundle.isFolder ? it.rel : p.basename(it.rel)));
          req.headers.set('x-count', '${bundle.count}');
          req.headers.set('x-index', '$i');
        }
        req.headers.contentType = ContentType.binary;
        req.contentLength = it.size;
        var sent = 0;
        await req.addStream(TransferBoost.read(it.file).map((chunk) {
          sent += chunk.length;
          onProgress?.call(done + sent, total, i, it.rel);
          return chunk;
        }));
        final res = await req.close().timeout(const Duration(minutes: 5));
        await res.drain<void>().timeout(const Duration(minutes: 1));
        if (res.statusCode == HttpStatus.conflict) return 'The other device is busy receiving.';
        if (res.statusCode != 200) return 'The other device could not save ${it.rel}.';
        done += it.size;
      }
      return null;
    } catch (_) {
      return cancel?.value == true ? 'Cancelled.' : 'The copy stopped. Stay on the same Wi-Fi and try again.';
    } finally {
      cancel?.removeListener(abort);
      await TransferBoost.end();
      client.close(force: true);
    }
  }

  static Future<List<String>> lanIps() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    );
    final good = <String>[];
    final other = <String>[];
    for (final interface in interfaces) {
      final n = interface.name.toLowerCase();
      final virtualish = n.contains('vpn') || n.contains('tap') || n.contains('tun') ||
          n.contains('wireguard') || n.contains('virtual') || n.contains('vethernet') ||
          n.contains('surfshark') || n.contains('veepn') || n.contains('rmnet');
      for (final address in interface.addresses) {
        if (address.isLoopback) continue;
        final ip = address.address;
        final private = ip.startsWith('192.168.') || ip.startsWith('10.') || _isPrivate172(ip);
        if (private && !virtualish) {
          // Wi-Fi first.
          if (n.contains('wi') || n.contains('wlan')) {
            good.insert(0, ip);
          } else {
            good.add(ip);
          }
        } else if (private) {
          other.add(ip);
        }
      }
    }
    return [...good, ...other];
  }

  static bool _isPrivate172(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4 || parts[0] != '172') return false;
    final second = int.tryParse(parts[1]);
    return second != null && second >= 16 && second <= 31;
  }

  static String newCode() {
    final random = Random.secure();
    return List.generate(6, (_) => _alphabet[random.nextInt(_alphabet.length)]).join();
  }
}

class DropState {
  const DropState({
    required this.title,
    required this.received,
    required this.total,
    this.busy = false,
    this.failed = false,
    this.file,
    this.detail = '',
  });

  final String detail;
  final String title;
  final int received;
  final int total;
  final bool busy;
  final bool failed;
  final File? file;

  double? get fraction => total > 0 ? received / total : null;
}

class HandoffOffer {
  const HandoffOffer({
    required this.code,
    required this.ips,
    required this.port,
    required this.fileName,
    required this.title,
    required this.size,
  });

  final String code;
  final List<String> ips;
  final int port;
  final String fileName;
  final String title;
  final int size;

  String get url => 'http://${ips.first}:$port/v/$code/${Uri.encodeComponent(fileName)}';
}

class HandoffTarget {
  const HandoffTarget({
    required this.host,
    required this.port,
    required this.code,
    required this.fileName,
    required this.title,
    required this.size,
    this.sid,
    this.sp,
    this.sendsInSession = false,
    this.version,
    this.senderName,
    this.senderKind,
  });

  final String host;
  final int port;
  final String code;
  final String fileName;
  final String title;
  final int size;

  /// 1.0.36+ senders: a pairing token and inbox port to open a lasting
  /// session from a typed code (not only from the hotspot QR).
  final String? sid;
  final int? sp;
  final bool sendsInSession;
  final String? version;
  final String? senderName;
  final String? senderKind;

  bool get hasFile => size > 0 && fileName.isNotEmpty;

  String get videoUrl => 'http://$host:$port/v/$code/${Uri.encodeComponent(fileName)}';
}

String _sizeText(int bytes) {
  if (bytes <= 0) return '';
  const mb = 1024 * 1024;
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}

Future<void> showSendToPhone(BuildContext context, File file, String title) async {
  // Connected to a device: one tap sends it there (other ways stay available).
  if (ShareSession.active) {
    final handled = await offerSessionSend(context, file, title);
    if (handled || !context.mounted) return;
    if (ShareSession.hostsHotspot) {
      // The connected phone is on this phone's hotspot: a new code/hotspot
      // would cut it off, so keep to the session.
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text('Connected to ${ShareSession.peer.value?.name ?? 'a phone'} over Fast share. Disconnect first to use another way.'),
      ));
      return;
    }
  }
  final offer = await PhoneHandoff.offer(file, title: title);
  if (!context.mounted) return;
  final codeCtrl = TextEditingController();
  String? status;
  double? pushProgress;
  var pushing = false;
  // If the other device connects (Connect / session) while this is open, the
  // picked file goes first in the session and this dialog closes by itself.
  ShareSession.pendingFirst = file;
  ShareSession.pairLink = offer?.url;
  final next = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PairingUiScope(child: StatefulBuilder(
      builder: (context, setState) {
        Future<void> doPush() async {
          if (pushing) return;
          setState(() {
            pushing = true;
            status = 'Looking for that code on this Wi-Fi…';
            pushProgress = null;
          });
          final meter = TransferMeter();
          final error = await PhoneHandoff.push(
            file,
            codeCtrl.text,
            title: title,
            onProgress: (sent, total) {
              if (!context.mounted || !meter.update(sent, total)) return;
              setState(() {
                status = sent >= total && total > 0
                    ? 'Finishing… waiting for the other device to save it'
                    : 'Sending… ${(sent * 100 / (total == 0 ? 1 : total)).toStringAsFixed(0)}% · ${meter.label}';
                pushProgress = total > 0 ? sent / total : null;
              });
            },
          );
          if (!context.mounted) return;
          setState(() {
            pushing = false;
            pushProgress = error == null ? 1 : null;
            status = error ?? 'Sent ✓ Saved on the other device. ${meter.doneLabel}';
          });
        }

        final spaced = offer == null ? '' : '${offer.code.substring(0, 3)} ${offer.code.substring(3)}';
        final small = Theme.of(context).textTheme.bodySmall;
        return AlertDialog(
          title: const Text('Send to another device'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (HotspotShare.hostSupported) ...[
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    key: const ValueKey('hotspot-send'),
                    onPressed: pushing ? null : () => Navigator.pop(context, 'hotspot'),
                    icon: const Icon(Icons.wifi_tethering_rounded),
                    label: const Text('Fast share (hotspot)'),
                  ),
                  const SizedBox(height: 2),
                  Text(
                      DesktopSupport.isWindows
                          ? 'This PC opens its own Wi-Fi hotspot; the phone scans and joins it. No router needed.'
                          : 'Phone to phone, no Wi-Fi needed. Fastest.',
                      style: small,
                      textAlign: TextAlign.center),
                ],
                const SizedBox(height: 12),
                Text('Nearby devices — tap one to send', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                NearbyDeviceChips(file: file),
                const Divider(height: 24),
                Text('No device listed? Use a code', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 6),
                Text('1. Is the other device showing a code?', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: codeCtrl,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(hintText: 'Its code, e.g. K7P 2QX', isDense: true),
                        onSubmitted: (_) => doPush(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const ValueKey('push-send'),
                      onPressed: pushing ? null : doPush,
                      child: const Text('Send'),
                    ),
                  ],
                ),
                if (status != null) ...[
                  const SizedBox(height: 8),
                  if (pushing || pushProgress != null) LinearProgressIndicator(value: pushProgress),
                  const SizedBox(height: 4),
                  Text(status!, style: small),
                ],
                const Divider(height: 28),
                Text('2. Or let the other device scan / type this', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                if (offer == null)
                  Text('Connect to Wi-Fi to show a code here.', style: small)
                else ...[
                  Center(
                    child: ColoredBox(
                      color: Colors.white,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: QrImageView(data: offer.url, size: 168),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: SelectableText(
                      spaced,
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: 4,
                          ),
                    ),
                  ),
                  Text(
                    'On the other device: Receive › scan or type this code › Watch or Save. '
                    'Same Wi-Fi (${offer.ips.first}). Works for 15 minutes while this is open.',
                    style: small,
                  ),
                  if (DesktopSupport.isWindows)
                    Text(
                      'If the other device cannot find this PC, use option 1 instead '
                      '(or allow SocialSave when Windows asks).',
                      style: small,
                    ),
                ],
              ],
            ),
          ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    )),
  );
  if (identical(ShareSession.pendingFirst, file)) ShareSession.pendingFirst = null;
  // Connected (also an older app fetching by code): the server stays for
  // the session; Disconnect stops it.
  if (!ShareSession.active) {
    ShareSession.pairLink = null;
    await PhoneHandoff.stop();
  }
  if (next == 'hotspot' && context.mounted && !ShareSession.active) {
    await showHotspotSend(context, file, title);
  }
}

/// Sender side of Fast share: opens a local-only hotspot, serves the file on
/// it and shows a QR that carries the hotspot name and password.
/// One-tap "Hotspot share": opens the hotspot and its QR with nothing picked
/// yet. When the other device connects, both land on the Connected screen
/// and pick files there.
Future<void> showHotspotQuickShare(BuildContext context) async {
  if (ShareSession.active) {
    await openSessionScreen(context);
    return;
  }
  await showHotspotSend(context, null, 'Hotspot share');
}

Future<void> showHotspotSend(BuildContext context, File? file, String title) async {
  // 1.0.40 Xender-style pre-flight: open whatever is missing (permission,
  // Location, Hotspot...) by itself, tick it off, and only then show the
  // QR. Never a QR before the hotspot is really on.
  if (HotspotShare.supported || Plat.isWindows) {
    final ready = await runPreflight(context,
        title: 'Getting ready to share', items: await hotspotSenderItems());
    if (!ready) {
      if (!ShareSession.active && !Plat.isWindows) await HotspotShare.stop();
      return;
    }
    if (!context.mounted) return;
  }
  final result = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PairingUiScope(child: _HotspotSendDialog(file: file, title: title)),
  );
  if (identical(ShareSession.pendingFirst, file)) ShareSession.pendingFirst = null;
  // Closing the dialog never stops the hotspot of a live session.
  if (ShareSession.active && (result == 'session' || ShareSession.hostsHotspot || ShareSession.hostsHotspotPending)) {
    // The other phone connected: keep the hotspot (and the first file's
    // server) up for the whole session. Disconnect stops them.
    ShareSession.hostsHotspot = true;
    ShareSession.hostsHotspotPending = false;
    if (context.mounted && !ShareSession.screenOpen && result == 'session') await openSessionScreen(context);
    return;
  }
  ShareSession.pairLink = null;
  await PhoneHandoff.stop();
  await HotspotShare.stop();
}

/// Big, grouped Wi-Fi name / password / code with copy buttons, for joining
/// the hotspot by hand (PCs, or phones that cannot scan).
class _JoinByHand extends StatelessWidget {
  const _JoinByHand({required this.info, required this.code});
  final HotspotInfo info;
  final String code;

  static String _group(String s) {
    if (s.length <= 6) return s;
    final out = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && i % 4 == 0) out.write(' ');
      out.write(s[i]);
    }
    return out.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final big = theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 1.5);
    Widget row(String label, String shown, String copy, Key key) => Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: theme.textTheme.labelMedium),
                  SelectableText(shown, style: big),
                ],
              ),
            ),
            IconButton(
              key: key,
              tooltip: 'Copy $label',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: copy));
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$label copied')));
              },
              icon: const Icon(Icons.copy_rounded),
            ),
          ],
        );
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Or join by hand', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            row('Wi-Fi name', info.ssid, info.ssid, const ValueKey('hs-copy-ssid')),
            const SizedBox(height: 6),
            row('Password', _group(info.password), info.password, const ValueKey('hs-copy-pass')),
            const SizedBox(height: 6),
            row('SocialSave code', '${code.substring(0, 3)} ${code.substring(3)}', code, const ValueKey('hs-copy-code')),
            const SizedBox(height: 4),
            Text(
              'Join this Wi-Fi on the other device (type the password without spaces), '
              'then open SocialSave › Receive and type the code: both devices go to the Connected screen.',
              style: theme.textTheme.bodySmall,
            ),
            if (!info.custom)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Android picks this password itself on this phone; scanning the QR is quicker.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HotspotSendDialog extends StatefulWidget {
  const _HotspotSendDialog({required this.file, required this.title});
  final File? file;
  final String title;

  @override
  State<_HotspotSendDialog> createState() => _HotspotSendDialogState();
}

class _HotspotSendDialogState extends State<_HotspotSendDialog> {
  String _step = 'Checking permissions…';
  String? _error;

  /// 1.0.39 guided pre-flight: the blocker being fixed now (null = none).
  GuideStep? _guide;

  /// Shown inside the guide card (system hotspot name/password form).
  Widget? _guideChild;
  Timer? _poll;

  void _stopPoll() {
    _poll?.cancel();
    _poll = null;
  }

  /// Watches [check] every [every] and runs [then] once it is true.
  void _watch(Future<bool> Function() check, Future<void> Function() then, {Duration every = const Duration(seconds: 1)}) {
    _stopPoll();
    var busy = false;
    _poll = Timer.periodic(every, (_) async {
      if (busy || !mounted) return;
      busy = true;
      try {
        if (await check()) {
          _stopPoll();
          if (mounted) await then();
        }
      } catch (_) {
      } finally {
        busy = false;
      }
    });
  }

  final Set<String> _autoOpened = {};

  /// The hotspot went off while the QR was up: hide it now, guide again,
  /// and come back to a fresh QR once it is on.
  Future<void> _lost() async {
    // A live session reopens its own hotspot (ShareSession); leave it be.
    if (!mounted || ShareSession.active) return;
    _stopPoll();
    ShareSession.pairLink = null;
    setState(() {
      _info = null;
      _offer = null;
      _link = null;
      _step = 'The hotspot turned off. Getting it back…';
    });
    await PhoneHandoff.stop();
    await _start();
  }

  void _show(GuideStep step, {Widget? child}) {
    if (!mounted) return;
    setState(() {
      _guide = step;
      _guideChild = child;
      _error = null;
    });
  }
  HotspotInfo? _info;
  HandoffOffer? _offer;
  String? _link;
  var _meter = TransferMeter();
  bool _restarting = false;

  /// Band changed in the dialog: start the hotspot again on the new band.
  Future<void> _restart() async {
    if (_restarting) return;
    _restarting = true;
    setState(() {
      _info = null;
      _offer = null;
      _link = null;
      _error = null;
      _step = 'Restarting the hotspot…';
      _meter = TransferMeter();
    });
    ShareSession.hostsHotspotPending = false;
    await PhoneHandoff.stop();
    await HotspotShare.stop();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    _restarting = false;
    if (mounted) await _start();
  }
  int _size = 0;

  @override
  void initState() {
    super.initState();
    PhoneHandoff.served.addListener(_onServed);
    HotspotShare.event.addListener(_onEvent);
    ShareSession.pendingFirst = widget.file;
    ShareSession.peer.addListener(_onPeer);
    unawaited(_start());
  }

  @override
  void dispose() {
    PhoneHandoff.served.removeListener(_onServed);
    HotspotShare.event.removeListener(_onEvent);
    ShareSession.peer.removeListener(_onPeer);
    if (!ShareSession.active) ShareSession.hostsHotspotPending = false;
    _stopPoll();
    super.dispose();
  }

  bool _leaving = false;

  /// The other phone opened a session: move on to the "Connected" screen.
  void _onPeer() {
    if (_leaving || !mounted || ShareSession.peer.value == null || _info == null) return;
    _leaving = true;
    ShareSession.hostsHotspot = true;
    // The session lands by itself (closes this dialog, sends the file as the
    // first transfer). Fallback only if this dialog is somehow still up.
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && route.isCurrent) Navigator.pop(context, 'session');
    });
  }

  void _onServed() {
    if (!mounted || _size <= 0) return;
    final sent = min(PhoneHandoff.served.value, _size);
    if (_meter.update(sent, _size)) setState(() {});
  }

  void _onEvent() {
    final e = HotspotShare.event.value ?? '';
    if (e.startsWith('stopped') && mounted && _info != null && !_info!.system) {
      // The hotspot is gone: hide the QR at once and get it back.
      unawaited(_lost());
    }
  }

  Future<void> _start() async {
    _stopPoll();
    if (mounted) {
      setState(() {
        _guide = null;
        _guideChild = null;
        _error = null;
        _step = 'Checking…';
      });
    }
    try {
      if (Plat.isWindows) {
        await _startPc();
        return;
      }
      if (!HotspotShare.supported) throw const HotspotError('Fast share works between Android phones and Windows PCs.');
      final s = await HotspotShare.status();
      final sdk = (s['sdk'] as int?) ?? 0;
      if (sdk < 26) throw const HotspotError('Fast share needs Android 8 or newer on the sending phone.');
      // 1. Permission (Nearby devices on Android 13+, Location before).
      if (!await _ensurePermission(sdk)) return;
      // 2. Location services (Android 12 and older need them for a hotspot).
      if (sdk < 33 && s['locationOn'] != true) {
        _show(GuideStep(
          icon: Icons.location_off_rounded,
          title: 'Turn on Location',
          text: 'Android needs Location turned on to start a hotspot on this version. '
              'SocialSave doesn\'t use your location.',
          action: 'Open Location settings',
          onAction: () => HotspotShare.openSettings('location'),
          waiting: 'Continues by itself when Location is on.',
        ));
        _watch(() async => (await HotspotShare.status())['locationOn'] == true, _start);
        return;
      }
      // 3. SocialSave's own hotspot first: it picks 5 GHz on Auto (1.0.40:
      // the phone's Mobile Hotspot is only the fallback, since its band is
      // whatever Settings says, often 2.4 GHz).
      if (!mounted) return;
      setState(() => _step = 'Starting hotspot…');
      final HotspotInfo info;
      try {
        info = await HotspotShare.start();
      } on HotspotError catch (e) {
        await _appHotspotFailed(e);
        return;
      }
      await _ready(info);
    } catch (e) {
      debugPrint('[hotspot] start failed: $e');
      if (mounted) setState(() => _error = e is HotspotError ? e.message : 'Fast share could not start: $e');
    }
  }

  Future<bool> _ensurePermission(int sdk) async {
    final perm = sdk >= 33 ? Permission.nearbyWifiDevices : Permission.locationWhenInUse;
    if (await perm.isGranted) return true;
    final st = await perm.request();
    if (st.isGranted) return true;
    final name = sdk >= 33 ? 'Nearby devices' : 'Location';
    final forever = st.isPermanentlyDenied;
    _show(GuideStep(
      icon: Icons.verified_user_outlined,
      title: 'Allow "$name"',
      text: sdk >= 33
          ? 'Android asks for "Nearby devices" before an app can open a Wi-Fi hotspot. SocialSave only uses it for Fast share.'
          : 'This Android version needs Location permission for Wi-Fi hotspots. SocialSave doesn\'t use your location.',
      action: forever ? 'Open app settings' : 'Allow',
      onAction: () async {
        if (forever) {
          await HotspotShare.openSettings('app');
        } else if ((await perm.request()).isGranted) {
          await _start();
        }
      },
      waiting: forever ? 'Turn on "$name" under Permissions. Continues by itself.' : null,
    ));
    if (forever) _watch(() => perm.isGranted, _start);
    return false;
  }

  /// SocialSave's own hotspot didn't start (system hotspot on, maker
  /// blocks it...): guide the user to the phone's Hotspot instead.
  Future<void> _appHotspotFailed(HotspotError e) async {
    debugPrint('[hotspot] app hotspot failed (${e.code}): ${e.message}');
    final s = await HotspotShare.status();
    if (s['systemApOn'] == true) {
      await _useSystem();
      return;
    }
    final unknown = s['systemApOn'] == null;
    // Xender-style: open the Hotspot screen for the user, once per dialog.
    if (_autoOpened.add('hotspot')) unawaited(HotspotShare.openSettings('hotspot'));
    _show(GuideStep(
      icon: Icons.wifi_tethering_rounded,
      title: 'Turn on your phone\'s Hotspot',
      text: 'SocialSave couldn\'t open its own hotspot on this phone (${e.message}) '
          'Turn on Mobile Hotspot in Settings and come back: SocialSave carries on by itself.',
      action: 'Open Hotspot settings',
      onAction: () => HotspotShare.openSettings('hotspot'),
      secondary: 'Try SocialSave\'s hotspot again',
      onSecondary: () => unawaited(_start()),
      waiting: 'Waiting for the hotspot to turn on…',
    ));
    _watch(() async {
      final st = await HotspotShare.status();
      return st['apIp'] != null && (st['systemApOn'] == true || unknown);
    }, _useSystem);
  }

  /// The phone's own hotspot is on: use the name/password typed once.
  Future<void> _useSystem({bool edit = false}) async {
    final saved = await HotspotShare.savedSystemHotspot();
    if (saved != null && !edit) {
      if (!mounted) return;
      setState(() {
        _guide = null;
        _step = 'Using your phone\'s hotspot "${saved.ssid}"…';
      });
      await _ready(await HotspotShare.useSystemHotspot(saved.ssid, saved.password));
      return;
    }
    _show(
      const GuideStep(
        icon: Icons.wifi_tethering_rounded,
        title: 'Your phone\'s Hotspot is on',
        text: 'Type its name and password once (Settings › Hotspot shows them). '
            'SocialSave remembers them and puts them in the QR, so the other phone joins by itself.',
      ),
      child: SystemHotspotForm(
        ssid: saved?.ssid ?? '',
        password: saved?.password ?? '',
        onDone: (ssid, pass) async {
          await HotspotShare.saveSystemHotspot(ssid, pass);
          if (!mounted) return;
          setState(() {
            _guide = null;
            _guideChild = null;
            _info = null;
            _offer = null;
            _link = null;
            _step = 'Using your phone\'s hotspot "$ssid"…';
          });
          await _ready(await HotspotShare.useSystemHotspot(ssid, pass));
        },
      ),
    );
  }

  /// Windows: start Mobile hotspot, or explain why not and wait for it.
  Future<void> _startPc() async {
    if (mounted) setState(() => _step = 'Checking Mobile hotspot…');
    final block = await HotspotShare.prepare(sending: true);
    if (block != null) {
      _pcGuide(block);
      return;
    }
    if (mounted) setState(() => _step = 'Starting Mobile hotspot…');
    try {
      await _ready(await HotspotShare.start());
    } on HotspotError catch (e) {
      _pcGuide(e.message);
    }
  }

  void _pcGuide(String reason) {
    if (_autoOpened.add('pc-hotspot')) {
      unawaited(HotspotShare.openSettings(reason.contains('online') ? 'wifi' : 'hotspot'));
    }
    _show(GuideStep(
      icon: Icons.wifi_tethering_error_rounded,
      title: 'Turn on Mobile hotspot',
      text: '$reason\n\nYou can also turn on Mobile hotspot yourself in Windows Settings: '
          'SocialSave notices and carries on with its name and password.',
      action: 'Open Mobile hotspot settings',
      onAction: () => HotspotShare.openSettings('hotspot'),
      secondary: 'Try again',
      onSecondary: () => unawaited(_start()),
      waiting: 'Waiting for Mobile hotspot to turn on…',
    ));
    _watch(PcHotspot.isRunning, () async {
      if (mounted) {
        setState(() {
          _guide = null;
          _step = 'Mobile hotspot is on. Getting its name and password…';
        });
      }
      try {
        await _ready(await HotspotShare.start());
      } on HotspotError catch (e) {
        _pcGuide(e.message);
      }
    }, every: const Duration(seconds: 3));
  }

  /// The hotspot is up: serve, arm pairing and show the QR + code.
  Future<void> _ready(HotspotInfo info) async {
    try {
      if (!mounted) {
        if (!info.system) await HotspotShare.stop();
        return;
      }
      // 1.0.40: no QR until the hotspot is verified on and has its address.
      if (info.ip == null || !await HotspotShare.hotspotReady()) {
        debugPrint('[hotspot] not ready yet (ip=${info.ip}); no QR');
        if (Plat.isWindows) {
          _pcGuide('Mobile hotspot isn\'t on yet.');
        } else if (info.system) {
          await _appHotspotFailed(const HotspotError('your Hotspot is not on yet.'));
        } else {
          await _appHotspotFailed(const HotspotError('it did not get a network address.'));
        }
        return;
      }
      _size = widget.file == null ? 0 : await widget.file!.length();
      final offer = await PhoneHandoff.offer(widget.file, title: widget.title, preferIp: info.ip);
      if (offer == null) throw const HotspotError('Could not start sharing on the hotspot.');
      debugPrint('[hotspot] ready ssid=${info.ssid} ip=${info.ip} port=${offer.port} code=${offer.code} system=${info.system}');
      if (!mounted) return;
      // The QR also lets the other phone open a lasting two-way session.
      ShareSession.hostsHotspotPending = true;
      final pair = ShareSession.armPairing();
      setState(() {
        _guide = null;
        _guideChild = null;
        _info = info;
        _offer = offer;
        // sf=1: this sender sends the file inside the session (1.0.34+).
        _link = '${HotspotShare.link(offer.url, info)}&sid=$pair&sp=${NearbyService.inboxBoundPort}&sf=1';
      });
      ShareSession.pairLink = _link;
      // Watch the hotspot while the QR is up: if it goes off, hide the QR.
      if (info.system || Plat.isWindows) {
        _watch(() async => !await HotspotShare.hotspotReady(), _lost, every: const Duration(seconds: 3));
      }
    } catch (e) {
      debugPrint('[hotspot] ready failed: $e');
      if (mounted) setState(() => _error = e is HotspotError ? e.message : 'Fast share could not start: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final info = _info;
    final offer = _offer;
    final sent = min(PhoneHandoff.served.value, _size);
    final started = sent > 0;
    final done = _size > 0 && sent >= _size;
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.wifi_tethering_rounded),
          const SizedBox(width: 8),
          Expanded(child: Text(widget.file == null ? 'Hotspot share' : 'Fast share (hotspot)')),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.file == null
                    ? 'Connect first, then send any videos or files both ways.'
                    : widget.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 10),
              Center(
                child: HotspotBandPicker(
                  enabled: !started && !_restarting,
                  onChanged: (_) => unawaited(_restart()),
                ),
              ),
              if (info != null) ...[
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(info.band == 2 || info.band == 4 ? Icons.speed_rounded : Icons.wifi_rounded,
                        size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(info.bandLabel,
                          key: const ValueKey('hotspot-band-label'),
                          style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
                    ),
                  ],
                ),
                if (info.bandNote.isNotEmpty)
                  Text(info.bandNote, style: small, textAlign: TextAlign.center),
              ],
              const SizedBox(height: 12),
              if (_guide != null && info == null) ...[
                GuideStepCard(step: _guide!, child: _guideChild),
              ] else if (_error != null) ...[
                Icon(Icons.error_outline_rounded, color: theme.colorScheme.error, size: 36),
                const SizedBox(height: 8),
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text('You can still use "Send to another device" on the same Wi-Fi.',
                    style: small, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Center(
                  child: FilledButton.tonal(
                    key: const ValueKey('hotspot-retry'),
                    onPressed: () => unawaited(_start()),
                    child: const Text('Try again'),
                  ),
                ),
              ] else if (info == null || offer == null) ...[
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 12),
                Text(_step, textAlign: TextAlign.center),
              ] else ...[
                if (_guide != null) ...[
                  GuideStepCard(step: _guide!, child: _guideChild),
                  const SizedBox(height: 10),
                ],
                Center(
                  child: ColoredBox(
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: QrImageView(key: const ValueKey('hotspot-qr'), data: _link!, size: 200),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'On the other phone: SocialSave › Receive › scan this. '
                  'It joins this phone\'s hotspot by itself.',
                  style: small,
                  textAlign: TextAlign.center,
                ),
                if (Plat.isWindows) const FirewallPrompt(),
                const SizedBox(height: 10),
                _JoinByHand(info: info, code: offer.code),
                Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    TextButton.icon(
                      key: const ValueKey('wifi-qr-button'),
                      onPressed: () => showWifiQr(context, info),
                      icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                      label: const Text('Wi-Fi QR for cameras'),
                    ),
                    if (info.system)
                      TextButton.icon(
                        key: const ValueKey('sys-hs-edit'),
                        onPressed: () => unawaited(_useSystem(edit: true)),
                        icon: const Icon(Icons.edit_rounded, size: 18),
                        label: const Text('Change name/password'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (started) ...[
                  if (!done)
                    Center(
                      child: Text(
                        _meter.speed > 0 ? '${(_meter.speed / (1024 * 1024)).toStringAsFixed(1)} MB/s' : '— MB/s',
                        key: const ValueKey('hotspot-speed'),
                        style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                  LinearProgressIndicator(value: _size > 0 ? sent / _size : null),
                  const SizedBox(height: 4),
                  Text(
                    done
                        ? 'Sent ✓ ${_meter.doneLabel}'
                        : 'Sending… ${(sent * 100 / _size).toStringAsFixed(0)}% · ${_meter.label}',
                    style: small,
                  ),
                ] else
                  Text('Waiting for the other phone… (${info.ip ?? '?'}:${offer.port})', style: small),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('connection-help-button'),
          onPressed: () => showConnectionHelp(context),
          child: const Text('Connection help'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(done ? 'Done' : (_error != null || _guide != null ? 'Close' : 'Stop')),
        ),
      ],
    );
  }
}

/// Returns true when a copy was saved (so the Library can refresh).
Future<bool> showReceiveFromPhone(BuildContext context) async {
  // 1.0.40: Wi-Fi, permission, Location and camera first, opened for the
  // user one by one; the scanner shows once everything is ready.
  final needs = await receiverItems();
  if (needs.isNotEmpty) {
    if (!context.mounted) return false;
    if (!await runPreflight(context, title: 'Getting ready to receive', items: needs)) return false;
  }
  if (!context.mounted) return false;
  final controller = TextEditingController();
  var picked = false;
  final myCode = await PhoneHandoff.openDrop();
  if (!context.mounted) {
    await PhoneHandoff.closeDrop();
    return false;
  }
  final raw = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      return PairingUiScope(child: ValueListenableBuilder<DropState?>(
        valueListenable: PhoneHandoff.drop,
        builder: (context, dropState, _) {
          if (dropState != null && !picked) {
            picked = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) Navigator.pop(context, '__drop__');
            });
          }
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      title: const Text('Receive a video'),
                      subtitle: Text(HotspotShare.supported
                          ? 'Scan the sender\'s QR (it joins its hotspot), or both devices on the same Wi-Fi.'
                          : 'Both devices on the same Wi-Fi.'),
                      trailing: TextButton(
                        key: const ValueKey('receive-help'),
                        onPressed: () => showConnectionHelp(context),
                        child: const Text('Help'),
                      ),
                    ),
                    if (HotspotShare.supported) const WifiOffBanner(),
                    if (myCode != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Card(
                          margin: EdgeInsets.zero,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              children: [
                                const Text('Code for this device'),
                                SelectableText(
                                  '${myCode.substring(0, 3)} ${myCode.substring(3)}',
                                  key: const ValueKey('my-drop-code'),
                                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 4,
                                      ),
                                ),
                                Text(
                                  'On the sending phone or PC: Send video › type this code › Send. Keep this open.',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text('…or enter the code shown on the sending device'),
                    ),
                    if (Plat.isWindows)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: FirewallPrompt(compact: true),
                      ),
                    if (!DesktopSupport.isWindows)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: QrScanner(
                          onCode: (value) {
                            if (picked || !value.startsWith('http')) return;
                            picked = true;
                            Navigator.pop(context, value);
                          },
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: controller,
                              textCapitalization: TextCapitalization.characters,
                              decoration: const InputDecoration(
                                hintText: 'Sender code, e.g. K7P 2QX',
                                isDense: true,
                              ),
                              onSubmitted: (v) {
                                picked = true;
                                Navigator.pop(context, v.trim());
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () {
                              picked = true;
                              Navigator.pop(context, controller.text.trim());
                            },
                            child: const Text('Find'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ));
    },
  );
  if (raw == '__drop__' && context.mounted) {
    final saved = await _showDropProgress(context);
    await PhoneHandoff.closeDrop();
    PhoneHandoff.drop.value = null;
    return saved;
  }
  await PhoneHandoff.closeDrop();
  PhoneHandoff.drop.value = null;
  if (raw == null || raw.isEmpty || !context.mounted) return false;
  return receiveHandoff(context, raw);
}

Future<bool> _showDropProgress(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final done = Completer<DropState>();
  void listener() {
    final v = PhoneHandoff.drop.value;
    if (v != null && !v.busy && !done.isCompleted) done.complete(v);
  }
  PhoneHandoff.drop.addListener(listener);
  listener();
  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('Receiving…'),
      content: ValueListenableBuilder<DropState?>(
        valueListenable: PhoneHandoff.drop,
        builder: (context, v, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(v?.title ?? '', maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: v?.fraction),
            const SizedBox(height: 6),
            Text(v == null ? '' : '${v.fraction == null ? '' : '${(v.fraction! * 100).toStringAsFixed(0)}% · '}${v.detail}'),
          ],
        ),
      ),
    ),
  );
  final result = await done.future.timeout(const Duration(hours: 2),
      onTimeout: () => const DropState(title: '', received: 0, total: 0, failed: true));
  PhoneHandoff.drop.removeListener(listener);
  if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  await dialog;
  final file = result.file;
  messenger.showSnackBar(SnackBar(
    content: Text(file == null
        ? 'The copy did not finish. Try again on the same Wi-Fi.'
        : 'Saved to ${FileSystemEntity.isDirectorySync(file.path) ? file.path : file.parent.path}. ${result.detail}'),
    action: file == null
        ? null
        : !isVideoName(file.path)
            ? SnackBarAction(label: 'Open', onPressed: () => openWithSystem(file.path))
            : SnackBarAction(
                label: 'Play',
                onPressed: () => appRouter.push(
                  '/player',
                  extra: PlayerSession(title: result.title, platform: SocialPlatform.direct, filePath: file.path),
                ),
              ),
  ));
  return file != null;
}

/// Finds the sender, then asks Watch or Save.
Future<bool> receiveHandoff(BuildContext context, String raw, {String? mode}) async {
  final join = HotspotShare.parse(raw);
  if (join == null) return _receiveHandoff(context, raw, mode: mode);
  final messenger = ScaffoldMessenger.of(context);
  if (!HotspotShare.supported) {
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 12),
      content: Text('Join Wi-Fi "${join.ssid}" (password ${join.password}), then type the code in Receive.'),
    ));
    return false;
  }
  final blocked = await HotspotShare.prepare(sending: false);
  if (!context.mounted) return false;
  if (blocked != null) {
    messenger.showSnackBar(SnackBar(
      content: Text(blocked),
      action: blocked.contains('Wi-Fi')
          ? SnackBarAction(label: 'Turn on Wi-Fi', onPressed: () => HotspotShare.openSettings('wifi'))
          : null,
    ));
    return false;
  }
  // 1.0.39: live steps instead of snackbars, auto-retry, fix-it message.
  final progress = JoinProgress(join.ssid);
  final navigator = Navigator.of(context, rootNavigator: true);
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => JoinProgressDialog(progress: progress),
  ));
  var dialogOpen = true;
  void closeDialog() {
    if (dialogOpen) {
      dialogOpen = false;
      navigator.pop();
    }
  }

  final q = Uri.tryParse(raw.trim());
  final sid = q?.queryParameters['sid'];
  final sp = int.tryParse(q?.queryParameters['sp'] ?? '');
  final sendsInSession = q?.queryParameters['sf'] == '1';
  final code = (q != null && q.pathSegments.length >= 2 && q.pathSegments[0] == 'v') ? q.pathSegments[1] : null;
  var session = false;
  // 1.0.40: a 5 GHz-only hotspot is invisible to phones without 5 GHz.
  var has5 = true;
  try {
    has5 = (await HotspotShare.status())['has5'] != false;
  } catch (_) {}
  while (true) {
    progress.step.value = 0;
    if (join.on5 && !has5) {
      progress.detail.value = null;
      if (await progress.fail('The sender\'s hotspot is on 5 GHz and this phone can only see 2.4 GHz. '
          'On the sending device tap "2.4 GHz" (the QR changes), then tap Retry and scan again.')) {
        closeDialog();
        return false;
      }
      closeDialog();
      return false;
    }
    progress.detail.value = 'Tap Connect if Android asks.';
    HotspotError? joinError;
    // Auto-retry a few times: a hotspot that just started can be missed by
    // the first scan. A refusal the user tapped is not retried silently.
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        await HotspotShare.join(join.ssid, join.password);
        joinError = null;
        break;
      } on HotspotError catch (e) {
        joinError = e;
        await HotspotShare.leave();
        debugPrint('[hotspot] join try $attempt failed (${e.code}): ${e.message}');
        if (e.code == 'permission' || e.code == 'declined' || attempt == 3) break;
        progress.detail.value = 'Not joined yet. Trying again ($attempt of 3)…';
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    if (joinError != null) {
      // Already on the same Wi-Fi as the sender (or USB)? Find it there.
      if (code != null) {
        progress.step.value = 1;
        progress.detail.value = 'Couldn\'t join the hotspot. Looking on your current Wi-Fi instead…';
        final viaLan = await PhoneHandoff.resolve(code);
        if (viaLan != null && context.mounted) {
          closeDialog();
          return _receiveHandoff(context, code, mode: mode);
        }
      }
      progress.detail.value = null;
      final why = joinError.code == 'permission'
          ? 'SocialSave needs the Nearby devices (or Location) permission to join. Allow it in Settings › Apps › SocialSave.'
          : join.on5
              ? 'Couldn\'t join "${join.ssid}" on 5 GHz. ${has5 ? 'Move the phones closer, or on' : 'This phone can\'t see 5 GHz hotspots. On'} '
                  'the sending device tap "2.4 GHz" (the QR changes), then tap Retry and scan again.'
              : 'Couldn\'t join "${join.ssid}". Check that the sender still shows its QR, Wi-Fi is on here, and the phones are close. '
              'You can also join "${join.ssid}" in Wi-Fi settings (password ${join.password}) and type the code.';
      if (await progress.fail(why)) continue;
      closeDialog();
      return false;
    }
    final link = HotspotShare.lastLink;
    progress.step.value = 1;
    progress.detail.value = link == null || link.label.isEmpty ? null : 'Joined · ${link.label}';
    // Newer senders put a session token in the QR: stay connected afterwards.
    if (q != null && sid != null && sp != null) {
      String? err;
      // A fresh hotspot link can take a few seconds to carry traffic.
      for (var i = 0; i < 8; i++) {
        err = await ShareSession.connect(host: q.host, port: sp, pair: sid, link: 'hotspot');
        if (err == null || err.contains('Update') || err.contains('accept') || err.contains('already')) break;
        debugPrint('[session] hotspot pairing try ${i + 1}: $err');
        await Future<void>.delayed(const Duration(milliseconds: 1500));
      }
      session = err == null;
      if (session) ShareSession.joinedHotspot = true;
      debugPrint('[session] hotspot pairing ${session ? 'ok' : 'failed: $err'}');
      if (!session && !'$err'.contains('Update')) {
        // Joined but the sender doesn't answer: one probe before failing.
        final t = await PhoneHandoff.resolve(raw);
        if (t == null) {
          progress.detail.value = null;
          if (await progress.fail(
              'Joined "${join.ssid}" but couldn\'t find the other device. Keep Hotspot share open on the sender '
              '(on a PC, allow SocialSave in Windows Firewall), then tap Retry.')) {
            continue;
          }
          await HotspotShare.leave();
          closeDialog();
          return false;
        }
      }
    }
    break;
  }
  progress.step.value = 2;
  final link = HotspotShare.lastLink;
  progress.detail.value = link == null || link.label.isEmpty ? null : link.label;
  await Future<void>.delayed(const Duration(milliseconds: 700));
  closeDialog();
  if (session && sendsInSession && ShareSession.active) {
    // Xender-style: no Watch/Save step. The file arrives as the first item
    // in Transfers; the Connected screen is already open.
    messenger.hideCurrentSnackBar();
    return true;
  }
  try {
    if (!context.mounted) return false;
    return await _receiveHandoff(context, raw, mode: mode, viaHotspot: true);
  } finally {
    if (ShareSession.active) {
      // Full or limited session: the hotspot link stays for it.
      ShareSession.joinedHotspot = true;
      if (context.mounted) unawaited(openSessionScreen(context));
    } else {
      await HotspotShare.leave();
    }
  }
}

bool _hotspotAddress(String host) =>
    host.startsWith('192.168.137.') || host.startsWith('192.168.43.') || host.startsWith('192.168.49.');

/// 1.0.36: the receiver found the sender (typed code, Wi-Fi joined by hand,
/// or a QR whose session could not open). Open a lasting session from the
/// sender's /info details so both sides land on the Connected screen. When
/// that's impossible (older sender, connection refused) land anyway in a
/// limited session that says why and still receives.
Future<bool> _joinAfterFind(BuildContext context, HandoffTarget t, {required bool viaHotspot}) async {
  final messenger = ScaffoldMessenger.of(context);
  final link = viaHotspot || _hotspotAddress(t.host) ? 'hotspot' : 'wifi';
  final who = t.senderName ?? (t.senderKind == 'pc' ? 'the PC' : 'the other device');
  final whoCap = who.isEmpty ? who : '${who[0].toUpperCase()}${who.substring(1)}';
  String reason;
  if (t.sid != null && t.sp != null) {
    messenger.showSnackBar(SnackBar(duration: const Duration(seconds: 20), content: Text('Connecting to $who…')));
    String? err;
    for (var i = 0; i < 6; i++) {
      err = await ShareSession.connect(host: t.host, port: t.sp!, pair: t.sid, link: link);
      if (err == null || err.contains('accept') || err.contains('already') || ShareSession.active) break;
      debugPrint('[session] code pairing try ${i + 1}: $err');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
    messenger.hideCurrentSnackBar();
    if (err == null || ShareSession.active) {
      debugPrint('[session] code pairing ok with ${t.host}:${t.sp}');
      if (link == 'hotspot' && viaHotspot) ShareSession.joinedHotspot = true;
      if (!t.sendsInSession && t.hasFile && ShareSession.active) {
        // Sender doesn't push its picked file in the session: fetch it.
        ShareSession.receiveOffered(t);
      }
      return true;
    }
    debugPrint('[session] code pairing failed: $err');
    reason = '$err Files from $who still arrive here; '
        'sending to $who may not work until it connects fully.';
    if (Plat.isWindows) {
      reason += ' If Windows Firewall blocks SocialSave, allow it below.';
    }
  } else {
    reason = '$whoCap has an older SocialSave: files it sends arrive here by themselves. '
        'Update it to send both ways.';
  }
  ShareSession.startLimited(t, reason, link: link);
  if (link == 'hotspot' && viaHotspot) ShareSession.joinedHotspot = true;
  return true;
}

Future<bool> _receiveHandoff(BuildContext context, String raw, {String? mode, bool viaHotspot = false}) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(
    content: Text(viaHotspot ? 'Connected. Finding the video…' : 'Looking for the other device on this Wi-Fi…'),
  ));
  final joining = mode == null && !ShareSession.active;
  var found = await PhoneHandoff.resolve(raw, joining: joining);
  // A fresh hotspot link can need a moment before it carries traffic.
  for (var i = 0; viaHotspot && found == null && i < 6; i++) {
    await Future<void>.delayed(const Duration(seconds: 1));
    found = await PhoneHandoff.resolve(raw, joining: joining);
  }
  final target = found;
  messenger.hideCurrentSnackBar();
  if (!context.mounted) return false;
  if (target == null) {
    messenger.showSnackBar(const SnackBar(
      content: Text('Could not find it. Check the code, keep the code open on the other device, and use the same Wi-Fi.'),
    ));
    return false;
  }
  if (joining) {
    // Xender-style: no Watch/Save step; both devices land on Connected.
    return _joinAfterFind(context, target, viaHotspot: viaHotspot);
  }
  final choice = mode ??
      await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Video found'),
          content: Text('${target.title}\n${_sizeText(target.size)}'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            OutlinedButton.icon(
              onPressed: () => Navigator.pop(context, 'watch'),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Watch'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, 'save'),
              icon: const Icon(Icons.download_rounded),
              label: const Text('Save'),
            ),
          ],
        ),
      );
  if (choice == null || !context.mounted) return false;
  if (choice == 'watch') {
    await appRouter.push(
      '/player',
      extra: PlayerSession(
        title: target.title,
        platform: SocialPlatform.direct,
        networkUrl: target.videoUrl,
      ),
    );
    return false;
  }
  final progress = ValueNotifier<double?>(null);
  final detail = ValueNotifier<String>('');
  final meter = TransferMeter();
  final cancel = CancelToken();
  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('Saving…'),
      content: ValueListenableBuilder<double?>(
        valueListenable: progress,
        builder: (context, value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(target.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: value),
            const SizedBox(height: 6),
            ValueListenableBuilder<String>(
              valueListenable: detail,
              builder: (context, d, _) => Text(
                '${value == null ? '' : '${(value * 100).toStringAsFixed(0)}% · '}$d',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            cancel.cancel();
            Navigator.pop(context);
          },
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
  File? file;
  try {
    file = await PhoneHandoff.download(
      target,
      cancel: cancel,
      onProgress: (r, t) {
        if (viaHotspot) ShareSession.touch();
        if (!meter.update(r, t)) return;
        progress.value = t > 0 ? r / t : null;
        detail.value = meter.label;
      },
    );
  } catch (_) {
    file = null;
  }
  if (!cancel.isCancelled && context.mounted) Navigator.of(context, rootNavigator: true).pop();
  await dialog;
  progress.dispose();
  if (cancel.isCancelled || !context.mounted) return false;
  messenger.showSnackBar(SnackBar(
    content: Text(file == null
        ? 'The copy did not finish. Stay on the same Wi-Fi and try again.'
        : 'Saved to ${file.parent.path}. ${meter.doneLabel}.'),
  ));
  return file != null;
}

Future<void> showSoundClip(BuildContext context, String path) async {
  final kind = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ListTile(
            title: Text('Use 30 seconds as a sound'),
            subtitle: Text('The first 30 seconds of audio. The video file stays as it is.'),
          ),
          ListTile(
            leading: const Icon(Icons.ring_volume_outlined),
            title: const Text('Ringtone'),
            onTap: () => Navigator.pop(context, 'ringtone'),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('Notification'),
            onTap: () => Navigator.pop(context, 'notification'),
          ),
          ListTile(
            leading: const Icon(Icons.alarm_outlined),
            title: const Text('Alarm'),
            onTap: () => Navigator.pop(context, 'alarm'),
          ),
        ],
      ),
    ),
  );
  if (kind == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Making the sound…')));
  final result = await PhoneBody.clipSound(path: path, kind: kind);
  if (!context.mounted) return;
  messenger.showSnackBar(
    SnackBar(content: Text(result.message.isEmpty ? 'Could not make that sound.' : result.message)),
  );
}


/// Android: the system picker for one video or audio file, returned as a
/// readable path without loading it into memory (1.0.36's file_selector
/// path read the whole file and a 500 MB video crashed the app).
Future<({String path, String name})?> _pickVideoAndroid() async {
  final m = await MediaEvents.channel.invokeMapMethod<String, dynamic>('pickVideo');
  final path = m?['path'] as String?;
  if (path == null || path.isEmpty) return null;
  return (path: path, name: (m?['name'] as String?) ?? p.basename(path));
}

/// Opens the system file picker for one video.
Future<File?> pickVideoFile() async {
  if (Plat.isAndroid) {
    final picked = await _pickVideoAndroid();
    return picked == null ? null : File(picked.path);
  }
  final picked = await openFile(acceptedTypeGroups: _videoTypes);
  return picked == null ? null : File(picked.path);
}

const _videoTypes = [
  XTypeGroup(
    label: 'Videos',
    extensions: ['mp4', 'mkv', 'webm', 'mov', 'avi', 'm4v', '3gp', 'mp3', 'm4a'],
    mimeTypes: ['video/*', 'audio/*'],
    uniformTypeIdentifiers: ['public.movie'],
  ),
];

/// Lets the user pick any video file, then shows the send code.
Future<void> pickAndSend(BuildContext context) async {
  if (Plat.isAndroid) {
    final picked = await _pickVideoAndroid();
    if (picked == null || !context.mounted) return;
    await showSendToPhone(context, File(picked.path), picked.name);
    return;
  }
  final picked = await openFile(acceptedTypeGroups: const [
    XTypeGroup(
      label: 'Videos',
      extensions: ['mp4', 'mkv', 'webm', 'mov', 'avi', 'm4v', '3gp', 'mp3', 'm4a'],
      mimeTypes: ['video/*', 'audio/*'],
      uniformTypeIdentifiers: ['public.movie'],
    ),
  ]);
  if (picked == null || !context.mounted) return;
  await showSendToPhone(context, File(picked.path), picked.name);
}

/// Two big buttons: Send and Receive, phone or PC, same Wi-Fi.
/// Opens the full Nearby share panel (send / receive / files / folder /
/// received) in a bottom sheet. Used by the compact "Share" buttons.
Future<void> showNearbySheet(
  BuildContext context, {
  VoidCallback? onReceived,
  Future<void> Function()? onSend,
  Future<File?> Function()? pickFile,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: NearbyShareBar(
          onReceived: onReceived,
          onSend: onSend == null
              ? null
              : () async {
                  Navigator.of(sheet).pop();
                  await onSend();
                },
          pickFile: pickFile,
          flat: true,
        ),
      ),
    ),
  );
}

class NearbyShareBar extends StatelessWidget {
  const NearbyShareBar({
    super.key,
    this.onReceived,
    this.onSend,
    this.pickFile,
    this.compact = false,
    this.flat = false,
  });

  /// Picks the video to send when a nearby device is tapped.
  final Future<File?> Function()? pickFile;

  final VoidCallback? onReceived;

  /// Optional custom "send" (e.g. choose from the Library list).
  final Future<void> Function()? onSend;

  /// One slim row: nearby devices + Send / Receive / more.
  final bool compact;

  /// No card around it (inside a sheet).
  final bool flat;

  Future<void> _receive(BuildContext context) async {
    final saved = await showReceiveFromPhone(context);
    if (saved) onReceived?.call();
  }

  void _openReceived(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ReceivedScreen()));
  }

  Widget _compact(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.wifi_tethering_rounded, color: scheme.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Nearby share',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                FilledButton.tonalIcon(
                  key: const ValueKey('nearby-send'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: () => onSend != null ? onSend!() : pickAndSend(context),
                  icon: const Icon(Icons.send_rounded, size: 18),
                  label: const Text('Send'),
                ),
                const SizedBox(width: 6),
                OutlinedButton.icon(
                  key: const ValueKey('nearby-receive'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: () => _receive(context),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Receive'),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More sharing options',
                  onSelected: (value) {
                    switch (value) {
                      case 'files':
                        pickAndSendBundle(context, folder: false);
                      case 'folder':
                        pickAndSendBundle(context, folder: true);
                      case 'received':
                        _openReceived(context);
                      case 'connect':
                        showConnectPicker(context);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'connect', child: ListTile(leading: Icon(Icons.link_rounded), title: Text('Connect (send both ways)'))),
                    PopupMenuItem(value: 'files', child: ListTile(leading: Icon(Icons.file_present_rounded), title: Text('Send files'))),
                    PopupMenuItem(value: 'folder', child: ListTile(leading: Icon(Icons.drive_folder_upload_rounded), title: Text('Send a folder'))),
                    PopupMenuItem(value: 'received', child: ListTile(leading: Icon(Icons.inventory_2_rounded), title: Text('Received files'))),
                  ],
                ),
              ],
            ),
            HotspotQuickButtons(onReceived: onReceived),
            NearbyDeviceChips(pickFile: pickFile ?? () => pickVideoFile()),
            const SessionBanner(),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const WebNearbyCard();
    if (compact) return _compact(context);
    final scheme = Theme.of(context).colorScheme;
    final body = Padding(
        padding: flat ? EdgeInsets.zero : const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.wifi_tethering_rounded, color: scheme.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Nearby share · same Wi-Fi or USB cable',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            HotspotQuickButtons(onReceived: onReceived),
            const SizedBox(height: 6),
            NearbyDeviceChips(pickFile: pickFile ?? () => pickVideoFile()),
            const SessionBanner(),
            ValueListenableBuilder<SessionPeer?>(
              valueListenable: ShareSession.peer,
              builder: (context, peer, _) => peer != null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: OutlinedButton.icon(
                        key: const ValueKey('nearby-connect'),
                        onPressed: () => showConnectPicker(context),
                        icon: const Icon(Icons.link_rounded),
                        label: const Text('Connect — stay connected and send both ways'),
                      ),
                    ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('nearby-send'),
                    onPressed: () => onSend != null ? onSend!() : pickAndSend(context),
                    icon: const Icon(Icons.qr_code_2_rounded),
                    label: const Text('Send video'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('nearby-receive'),
                    onPressed: () async {
                      final saved = await showReceiveFromPhone(context);
                      if (saved) onReceived?.call();
                    },
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    label: const Text('Receive'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('nearby-files'),
                    onPressed: () => pickAndSendBundle(context, folder: false),
                    icon: const Icon(Icons.file_present_rounded),
                    label: const Text('Pick files'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('nearby-folder'),
                    onPressed: () => pickAndSendBundle(context, folder: true),
                    icon: const Icon(Icons.drive_folder_upload_rounded),
                    label: const Text('Pick folder'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextButton.icon(
                    key: const ValueKey('nearby-received'),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ReceivedScreen())),
                    icon: const Icon(Icons.inventory_2_rounded),
                    label: const Text('Received'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    return flat ? body : Card(margin: EdgeInsets.zero, child: body);
  }
}


/// One-tap pair of quick buttons: "Hotspot share" (opens the hotspot and its
/// QR right away, no file needed) and "Scan to join" / "Receive" for the
/// other side. After connecting, both land on the Connected screen.
class HotspotQuickButtons extends StatelessWidget {
  const HotspotQuickButtons({super.key, this.dense = false, this.onReceived});
  final bool dense;
  final VoidCallback? onReceived;

  @override
  Widget build(BuildContext context) {
    final height = dense ? 36.0 : 44.0;
    final canHost = HotspotShare.hostSupported;
    final joinLabel = HotspotShare.supported ? 'Scan to join' : 'Receive';
    return ValueListenableBuilder<SessionPeer?>(
      valueListenable: ShareSession.peer,
      builder: (context, peer, _) {
        if (peer != null) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsets.only(top: dense ? 6 : 8),
          child: Row(
            children: [
              if (canHost) ...[
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('quick-hotspot-share'),
                    style: FilledButton.styleFrom(
                      minimumSize: Size(0, height),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      visualDensity: dense ? VisualDensity.compact : null,
                    ),
                    onPressed: () => showHotspotQuickShare(context),
                    icon: Icon(Icons.wifi_tethering_rounded, size: dense ? 16 : 20),
                    label: const Text('Hotspot share', maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('quick-scan-join'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: Size(0, height),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: dense ? VisualDensity.compact : null,
                  ),
                  onPressed: () async {
                    final saved = await showReceiveFromPhone(context);
                    if (saved) onReceived?.call();
                  },
                  icon: Icon(Icons.qr_code_scanner_rounded, size: dense ? 16 : 20),
                  label: Text(joinLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Android quick actions: the Quick Settings tile "SocialSave hotspot share"
/// and the launcher shortcuts (long-press the icon): Paste link, Hotspot
/// share, Library. Also opens links shared from other apps on any screen.
void listenForQuickActions() {
  if (!Plat.isAndroid) return;
  var busy = false;
  Future<void> run(Object? action) async {
    if (busy || action is! String) return;
    if (action != 'hotspot_share' && action != 'paste' && action != 'library') return;
    busy = true;
    try {
      try {
        await MediaEvents.channel.invokeMethod<void>('consumeQuickAction');
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final ctx = appRouter.routerDelegate.navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      switch (action) {
        case 'hotspot_share':
          await showHotspotQuickShare(ctx);
        case 'library':
          appRouter.go('/library');
        case 'paste':
          appRouter.go('/');
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final home = ProviderScope.containerOf(ctx, listen: false);
          await home.read(homeControllerProvider.notifier).pasteFromClipboard();
          final state = home.read(homeControllerProvider);
          if (state.error == null && state.url.isNotEmpty) {
            HapticFeedback.lightImpact();
            unawaited(appRouter.push('/preview', extra: state.url));
          } else if (ctx.mounted) {
            ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
              const SnackBar(content: Text('Copy a video link first, then try again.')),
            );
          }
      }
    } finally {
      busy = false;
    }
  }

  // A link shared from TikTok, Instagram, YouTube… while SocialSave is open
  // (1.0.37: one activity, so the link arrives here instead of a second copy).
  var sharing = false;
  Future<void> shared(Object? _) async {
    if (sharing) return;
    sharing = true;
    try {
      String? text;
      try {
        text = await MediaEvents.channel.invokeMethod<String>('consumeSharedText');
      } catch (_) {}
      if (text == null || text.trim().isEmpty) return;
      final ctx = appRouter.routerDelegate.navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      final home = ProviderScope.containerOf(ctx, listen: false);
      final controller = home.read(homeControllerProvider.notifier)..setUrl(text);
      final url = controller.validatedUrl();
      if (url == null) return;
      HapticFeedback.lightImpact();
      unawaited(appRouter.push('/preview', extra: url));
    } finally {
      sharing = false;
    }
  }

  MediaEvents.on('sharedText', shared);
  MediaEvents.on('quickAction', run);
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      final a = await MediaEvents.channel.invokeMethod<dynamic>('consumeQuickAction');
      if (a != null) await run(a);
    } catch (_) {}
  });
}
