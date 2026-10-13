import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:file_selector/file_selector.dart';
import 'package:social_save/features/library/bundle_transfer.dart';
import 'package:social_save/features/library/bundle_ui.dart';
import 'package:social_save/features/library/transfer_boost.dart';
import 'package:social_save/features/library/transfer_meter.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
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

  static Future<HandoffOffer?> offer(File file, {String? title}) async {
    await stop();
    if (!file.existsSync()) return null;
    final ips = await lanIps();
    if (ips.isEmpty) return null;
    final code = newCode();
    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: false);
    } catch (_) {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _server = server;
    final name = p.basename(file.path);
    final offer = HandoffOffer(
      code: code,
      ips: ips,
      port: server.port,
      fileName: name,
      title: title ?? p.basenameWithoutExtension(name),
      size: await file.length(),
    );
    current = offer;
    _timer = Timer(lifetime, () => unawaited(stop()));
    unawaited(_serve(server, file, offer));
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

  static Future<void> _serve(HttpServer server, File file, HandoffOffer offer) async {
    try {
      await for (final request in server) {
        unawaited(_handle(request, file, offer));
      }
    } catch (_) {}
  }

  static Future<void> _handle(HttpRequest request, File file, HandoffOffer offer) async {
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
      if (parts[0] == 'info') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'app': 'socialsave',
          'role': 'sender',
          'code': offer.code,
          'name': offer.fileName,
          'title': offer.title,
          'size': offer.size,
        }));
        await res.close();
        return;
      }
      if (parts[0] != 'v' || (request.method != 'GET' && request.method != 'HEAD')) {
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
        await res.addStream(TransferBoost.read(file, start, end + 1));
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
  static Future<HandoffTarget?> resolve(String raw) async {
    final text = raw.trim();
    final uri = Uri.tryParse(text);
    if (uri != null && uri.scheme == 'http' && uri.host.isNotEmpty) {
      final segs = uri.pathSegments;
      if (segs.length >= 2 && segs[0] == 'v') {
        return _probe(uri.host, uri.port, segs[1].toUpperCase());
      }
      return null;
    }
    final code = normalizeCode(text);
    if (code == null) return null;
    final viaUdp = await _discoverUdp(code);
    if (viaUdp != null) return viaUdp;
    return _sweep(code);
  }

  static String? normalizeCode(String text) {
    final code = text.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
    if (code.length != 6) return null;
    return code;
  }

  static Future<HandoffTarget?> _discoverUdp(String code, {String role = 'sender'}) async {
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
          unawaited(_probe(dg.address.address, port, code, role: role).then((t) {
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

  static Future<HandoffTarget?> _sweep(String code, {int port = port, String role = 'sender'}) async {
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
        final t = await _probe(host, port, code, role: role, timeout: const Duration(milliseconds: 900));
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
      {String role = 'sender', Duration timeout = const Duration(seconds: 4)}) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.getUrl(Uri.http('$host:$port', '/info/$code')).timeout(timeout);
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
  });

  final String host;
  final int port;
  final String code;
  final String fileName;
  final String title;
  final int size;

  String get videoUrl => 'http://$host:$port/v/$code/${Uri.encodeComponent(fileName)}';
}

String _sizeText(int bytes) {
  if (bytes <= 0) return '';
  const mb = 1024 * 1024;
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}

Future<void> showSendToPhone(BuildContext context, File file, String title) async {
  final offer = await PhoneHandoff.offer(file, title: title);
  if (!context.mounted) return;
  final codeCtrl = TextEditingController();
  String? status;
  double? pushProgress;
  var pushing = false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
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
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
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
                        child: QrImageView(data: offer.url, size: 180),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
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
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        );
      },
    ),
  );
  await PhoneHandoff.stop();
}

/// Returns true when a copy was saved (so the Library can refresh).
Future<bool> showReceiveFromPhone(BuildContext context) async {
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
      return ValueListenableBuilder<DropState?>(
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
                    const ListTile(
                      title: Text('Receive a video'),
                      subtitle: Text('Both devices on the same Wi-Fi.'),
                    ),
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
                    if (!DesktopSupport.isWindows)
                      SizedBox(
                        height: 220,
                        child: MobileScanner(
                          onDetect: (capture) {
                            final value = capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue;
                            if (picked || value == null || !value.startsWith('http')) return;
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
      );
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
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Looking for the other device on this Wi-Fi…')));
  final target = await PhoneHandoff.resolve(raw);
  messenger.hideCurrentSnackBar();
  if (!context.mounted) return false;
  if (target == null) {
    messenger.showSnackBar(const SnackBar(
      content: Text('Could not find it. Check the code, keep the code open on the other device, and use the same Wi-Fi.'),
    ));
    return false;
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


/// Opens the system file picker for one video.
Future<File?> pickVideoFile() async {
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
class NearbyShareBar extends StatelessWidget {
  const NearbyShareBar({super.key, this.onReceived, this.onSend, this.pickFile});

  /// Picks the video to send when a nearby device is tapped.
  final Future<File?> Function()? pickFile;

  final VoidCallback? onReceived;

  /// Optional custom "send" (e.g. choose from the Library list).
  final Future<void> Function()? onSend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.wifi_tethering_rounded, color: scheme.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Nearby share  •  phone ↔ PC on the same Wi-Fi',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            NearbyDeviceChips(pickFile: pickFile ?? () => pickVideoFile()),
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
      ),
    );
  }
}
