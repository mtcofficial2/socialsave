import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:social_save/features/library/nearby_service.dart';

/// A saved video playing on a Social Save computer on this Wi-Fi.
class MirrorCommand {
  const MirrorCommand({required this.id, required this.action, required this.positionMs});

  final int id;
  final String action;
  final int positionMs;
}

class MirrorPlay {
  const MirrorPlay({
    required this.title,
    required this.url,
    required this.positionMs,
    required this.from,
  });

  final String title;
  final String url;
  final int positionMs;
  final String from;
}

enum MirrorOutcome { started, none, failed, cancelled }

/// Phone serves the file. The computer plays it. The phone stays the remote.
class LanMirror {
  LanMirror._();

  static void Function(MirrorPlay play)? onOpen;

  static final commands = StreamController<MirrorCommand>.broadcast();
  static MirrorCommand? pending;

  static final Map<String, File> _files = {};
  static String? _token;
  static NearbyDevice? _peer;
  static int _seq = 0;
  static int? _startMs;
  static String? _startUrl;

  static void install() {
    final previous = NearbyService.extraRoute;
    NearbyService.extraRoute = (req, parts) async {
      if (await serve(req, parts)) return true;
      if (previous != null) return previous(req, parts);
      return false;
    };
  }

  static Duration? claimStart(String url) {
    if (_startUrl == null || url != _startUrl || _startMs == null) return null;
    final ms = _startMs!;
    _startMs = null;
    _startUrl = null;
    return Duration(milliseconds: ms);
  }

  static Future<MirrorOutcome> cast(
    BuildContext context, {
    required String path,
    required String title,
    int positionMs = 0,
    int durationMs = 0,
  }) async {
    final file = File(path);
    if (!file.existsSync()) {
      _note(context, 'That video is not on this phone.');
      return MirrorOutcome.failed;
    }
    final computers = await _computers();
    if (computers.isEmpty) return MirrorOutcome.none;
    if (!context.mounted) return MirrorOutcome.cancelled;
    final picked = computers.length == 1 ? computers.first : await _pick(context, computers);
    if (picked == null) return MirrorOutcome.cancelled;
    if (!context.mounted) return MirrorOutcome.cancelled;
    final error = await _start(picked, file, title, positionMs);
    if (!context.mounted) return MirrorOutcome.failed;
    if (error != null) {
      _note(context, error);
      return MirrorOutcome.failed;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _MirrorRemote(
        name: picked.name,
        durationMs: durationMs,
        positionMs: positionMs,
      ),
    );
    await send('stop');
    return MirrorOutcome.started;
  }

  static Future<void> send(String action, {int positionMs = 0}) async {
    final peer = _peer;
    final token = _token;
    if (peer == null || token == null) return;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.postUrl(Uri.http('${peer.host}:${peer.port}', '/mirror/cmd'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'token': token, 'action': action, 'positionMs': positionMs}));
      final res = await req.close().timeout(const Duration(seconds: 4));
      await res.drain<void>();
    } catch (_) {
    } finally {
      client.close(force: true);
    }
    if (action == 'stop') _clear();
  }

  static Future<bool> serve(HttpRequest req, List<String> parts) async {
    if (parts.isEmpty || parts.first != 'm' && parts.first != 'mirror') return false;
    if ((req.method == 'GET' || req.method == 'HEAD') && parts.length == 3 && parts[0] == 'm') {
      await _sendFile(req, parts[1]);
      return true;
    }
    if (req.method == 'POST' && parts.length == 1 && parts[0] == 'mirror') {
      await _accept(req);
      return true;
    }
    if (req.method == 'POST' && parts.length == 2 && parts[0] == 'mirror' && parts[1] == 'cmd') {
      await _takeCommand(req);
      return true;
    }
    return false;
  }

  static Future<List<NearbyDevice>> _computers() async {
    NearbyService.ping();
    final until = DateTime.now().add(const Duration(milliseconds: 2000));
    while (DateTime.now().isBefore(until)) {
      final found = NearbyService.devices.value.where((device) => device.isPc).toList();
      if (found.isNotEmpty) return found;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return NearbyService.devices.value.where((device) => device.isPc).toList();
  }

  static Future<NearbyDevice?> _pick(BuildContext context, List<NearbyDevice> computers) {
    return showModalBottomSheet<NearbyDevice>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Play on a computer', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            for (final computer in computers)
              ListTile(
                leading: const Icon(Icons.computer_rounded),
                title: Text(computer.name),
                subtitle: const Text('Same Wi-Fi'),
                onTap: () => Navigator.pop(context, computer),
              ),
          ],
        ),
      ),
    );
  }

  static Future<String?> _start(NearbyDevice computer, File file, String title, int positionMs) async {
    final token = _publish(file);
    final ext = _ext(file.path);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.postUrl(Uri.http('${computer.host}:${computer.port}', '/mirror'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'name': NearbyService.name,
        'title': title,
        'port': NearbyService.inboxBoundPort,
        'token': token,
        'ext': ext,
        'positionMs': positionMs,
      }));
      final res = await req.close().timeout(const Duration(seconds: 8));
      final text = await utf8.decoder.bind(res).join();
      if (res.statusCode == HttpStatus.notFound) {
        _files.remove(token);
        return '${computer.name} needs the newer Social Save before it can play this.';
      }
      if (res.statusCode != HttpStatus.ok) {
        _files.remove(token);
        return '${computer.name} could not start the video.';
      }
      final body = jsonDecode(text);
      if (body is! Map || body['ok'] != true) {
        _files.remove(token);
        return '${computer.name} could not start the video.';
      }
      _token = token;
      _peer = computer;
      return null;
    } on SocketException {
      _files.remove(token);
      return 'Could not reach ${computer.name}. Keep both on the same Wi-Fi, and allow Social Save in the computer firewall.';
    } catch (_) {
      _files.remove(token);
      return '${computer.name} did not answer. Open Social Save on the computer and try again.';
    } finally {
      client.close(force: true);
    }
  }

  static String _publish(File file) {
    final random = Random.secure();
    const alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final token = List.generate(18, (_) => alphabet[random.nextInt(alphabet.length)]).join();
    _files[token] = file;
    return token;
  }

  static void _clear() {
    final token = _token;
    _token = null;
    _peer = null;
    if (token != null) _files.remove(token);
  }

  static Future<void> _accept(HttpRequest req) async {
    final res = req.response;
    final peer = req.connectionInfo?.remoteAddress;
    if (peer == null || !lanAddress(peer)) {
      res.statusCode = HttpStatus.forbidden;
      await res.close();
      return;
    }
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
    } catch (_) {
      res.statusCode = HttpStatus.badRequest;
      await res.close();
      return;
    }
    final token = '${body['token'] ?? ''}';
    final port = (body['port'] as num?)?.toInt() ?? 0;
    final ext = _ext('${body['ext'] ?? 'mp4'}');
    final title = '${body['title'] ?? 'Video'}'.trim();
    final positionMs = (body['positionMs'] as num?)?.toInt() ?? 0;
    if (!_safeToken(token) || port <= 0 || port > 65535) {
      res.statusCode = HttpStatus.badRequest;
      await res.close();
      return;
    }
    final host = peer.address;
    final url = 'http://$host:$port/m/$token/video.$ext';
    _startMs = positionMs < 0 ? 0 : positionMs;
    _startUrl = url;
    _token = token;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode({'ok': true}));
    await res.close();
    final open = onOpen;
    if (open != null) {
      open(MirrorPlay(
        title: title.isEmpty ? 'Video' : title,
        url: url,
        positionMs: _startMs ?? 0,
        from: '${body['name'] ?? 'Phone'}',
      ));
    }
  }

  static Future<void> _takeCommand(HttpRequest req) async {
    final res = req.response;
    final peer = req.connectionInfo?.remoteAddress;
    if (peer == null || !lanAddress(peer)) {
      res.statusCode = HttpStatus.forbidden;
      await res.close();
      return;
    }
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
    } catch (_) {
      res.statusCode = HttpStatus.badRequest;
      await res.close();
      return;
    }
    final token = '${body['token'] ?? ''}';
    if (token.isEmpty || token != _token) {
      res.statusCode = HttpStatus.forbidden;
      await res.close();
      return;
    }
    final action = '${body['action'] ?? ''}';
    if (action != 'play' && action != 'pause' && action != 'seek' && action != 'stop') {
      res.statusCode = HttpStatus.badRequest;
      await res.close();
      return;
    }
    final command = MirrorCommand(
      id: ++_seq,
      action: action,
      positionMs: (body['positionMs'] as num?)?.toInt() ?? 0,
    );
    pending = command;
    if (!commands.isClosed) commands.add(command);
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode({'ok': true}));
    await res.close();
  }

  static Future<void> _sendFile(HttpRequest req, String token) async {
    final res = req.response;
    final file = _files[token];
    if (file == null || !file.existsSync()) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    final length = await file.length();
    final range = byteRange(req.headers.value(HttpHeaders.rangeHeader), length);
    if (range == null) {
      res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
      await res.close();
      return;
    }
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    res.headers.contentType = ContentType('video', _ext(file.path) == 'webm' ? 'webm' : 'mp4');
    final size = range.end - range.start + 1;
    res.headers.contentLength = size;
    if (range.partial) {
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes ${range.start}-${range.end}/$length');
    }
    if (req.method == 'HEAD') {
      await res.close();
      return;
    }
    await res.addStream(file.openRead(range.start, range.end + 1));
    await res.close();
  }

  static void _note(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  static String _ext(String raw) {
    final dot = raw.lastIndexOf('.');
    final ext = (dot < 0 ? 'mp4' : raw.substring(dot + 1)).toLowerCase();
    final clean = ext.replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (clean.isEmpty || clean.length > 4) return 'mp4';
    return clean;
  }

  static bool _safeToken(String token) {
    return RegExp(r'^[A-Za-z0-9]{12,32}$').hasMatch(token);
  }
}

class ByteSpan {
  const ByteSpan({required this.start, required this.end, required this.partial});

  final int start;
  final int end;
  final bool partial;
}

/// `null` when the header asks for bytes outside the file.
ByteSpan? byteRange(String? header, int length) {
  if (length <= 0) return const ByteSpan(start: 0, end: 0, partial: false);
  if (header == null || !header.startsWith('bytes=')) {
    return ByteSpan(start: 0, end: length - 1, partial: false);
  }
  final spec = header.substring(6).split(',').first.trim();
  final dash = spec.indexOf('-');
  if (dash < 0) return null;
  final left = spec.substring(0, dash);
  final right = spec.substring(dash + 1);
  var start = left.isEmpty ? 0 : int.tryParse(left);
  var end = right.isEmpty ? length - 1 : int.tryParse(right);
  if (start == null || end == null) return null;
  if (left.isEmpty) {
    final tail = end;
    start = length - tail;
    end = length - 1;
  }
  if (start < 0 || end < start || start >= length) return null;
  if (end >= length) end = length - 1;
  return ByteSpan(start: start, end: end, partial: true);
}

bool lanAddress(InternetAddress address) {
  if (address.isLoopback || address.isLinkLocal) return true;
  if (address.type != InternetAddressType.IPv4) return false;
  final raw = address.rawAddress;
  if (raw.length != 4) return false;
  final a = raw[0];
  final b = raw[1];
  if (a == 10) return true;
  if (a == 192 && b == 168) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  return false;
}

class _MirrorRemote extends StatefulWidget {
  const _MirrorRemote({
    required this.name,
    required this.durationMs,
    required this.positionMs,
  });

  final String name;
  final int durationMs;
  final int positionMs;

  @override
  State<_MirrorRemote> createState() => _MirrorRemoteState();
}

class _MirrorRemoteState extends State<_MirrorRemote> {
  late int _position;
  bool _playing = true;

  @override
  void initState() {
    super.initState();
    _position = widget.positionMs < 0 ? 0 : widget.positionMs;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Playing on ${widget.name}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              'The computer has the picture. These controls stay with you.',
              style: TextStyle(fontSize: 13, height: 1.3, color: scheme.onSurfaceVariant),
            ),
            if (widget.durationMs > 0) ...[
              const SizedBox(height: 8),
              Slider(
                value: _position.clamp(0, widget.durationMs).toDouble(),
                max: widget.durationMs.toDouble(),
                onChanged: (value) => setState(() => _position = value.round()),
                onChangeEnd: (value) => LanMirror.send('seek', positionMs: value.round()),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      final next = !_playing;
                      setState(() => _playing = next);
                      LanMirror.send(next ? 'play' : 'pause', positionMs: _position);
                    },
                    icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                    label: Text(_playing ? 'Pause' : 'Play'),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Stop'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
