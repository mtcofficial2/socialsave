import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:social_save/core/platform/phone_body.dart';
import 'package:social_save/core/storage/download_path_service.dart';
import 'package:social_save/core/storage/media_store_service.dart';

/// One saved video, on the local network, for about ten minutes.
/// The bytes stay on the two phones. Render is not involved.
class PhoneHandoff {
  PhoneHandoff._();

  static HttpServer? _server;
  static Timer? _timer;

  static Future<String?> offer(File file) async {
    await stop();
    if (!file.existsSync()) return null;
    final ip = await _lanIp();
    if (ip == null) return null;
    final token = _tokenOf();
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    _timer = Timer(const Duration(minutes: 10), () {
      unawaited(stop());
    });
    unawaited(_serve(server, file, token));
    return 'http://$ip:${server.port}/v/$token';
  }

  static Future<void> _serve(HttpServer server, File file, String token) async {
    try {
      await for (final request in server) {
        final ok = request.method == 'GET' && request.uri.path == '/v/$token';
        if (!ok) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          continue;
        }
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType('video', 'mp4');
        request.response.headers.contentLength = await file.length();
        await request.response.addStream(file.openRead());
        await request.response.close();
        unawaited(stop());
        return;
      }
    } catch (_) {
      unawaited(stop());
    }
  }

  static Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
    }
  }

  static Future<File?> receive(String rawUrl) async {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return null;
    if (!uri.path.startsWith('/v/')) return null;
    final folder = await DownloadPathService().resolveDirectory(DownloadLocation.publicDownloads);
    final name = 'SocialSave-${DateTime.now().millisecondsSinceEpoch}.mp4';
    final dest = File(p.join(folder.path, name));
    await Dio().downloadUri(uri, dest.path);
    if (!dest.existsSync() || await dest.length() < 32) return null;
    try {
      await MediaStoreService().publishToDownloads(
        sourcePath: dest.path,
        fileName: name,
        mimeType: 'video/mp4',
      );
    } catch (_) {}
    return dest;
  }

  static Future<String?> _lanIp() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    );
    String? fallback;
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.isLoopback) continue;
        final ip = address.address;
        if (ip.startsWith('192.168.') || ip.startsWith('10.') || _isPrivate172(ip)) {
          return ip;
        }
        fallback ??= ip;
      }
    }
    return fallback;
  }

  static bool _isPrivate172(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4 || parts[0] != '172') return false;
    final second = int.tryParse(parts[1]);
    return second != null && second >= 16 && second <= 31;
  }

  static String _tokenOf() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}

Future<void> showSendToPhone(BuildContext context, File file, String title) async {
  final url = await PhoneHandoff.offer(file);
  if (!context.mounted) return;
  if (url == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Connect both phones to the same Wi-Fi, then try again.')),
    );
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Send to another phone'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          ColoredBox(
            color: Colors.white,
            child: QrImageView(data: url, size: 220),
          ),
          const SizedBox(height: 12),
          const Text(
            'Open SocialSave on the other phone and scan this code. The link works on this Wi-Fi for about ten minutes.',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            unawaited(PhoneHandoff.stop());
            Navigator.pop(context);
          },
          child: const Text('Close'),
        ),
      ],
    ),
  );
  await PhoneHandoff.stop();
}

Future<void> showReceiveFromPhone(BuildContext context) async {
  final controller = TextEditingController();
  final url = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text('Receive a video'),
                subtitle: Text('Scan the code from the other SocialSave phone, or paste the link.'),
              ),
              SizedBox(
                height: 240,
                child: MobileScanner(
                  onDetect: (capture) {
                    final value = capture.barcodes.isEmpty
                        ? null
                        : capture.barcodes.first.rawValue;
                    if (value == null || !value.startsWith('http')) return;
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
                        decoration: const InputDecoration(
                          hintText: 'http://192.168…',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, controller.text.trim()),
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  controller.dispose();
  if (url == null || url.isEmpty || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Copying the video…')));
  try {
    final file = await PhoneHandoff.receive(url);
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(file == null ? 'That link could not be saved.' : 'Saved on this phone.'),
      ),
    );
  } catch (_) {
    if (!context.mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('That link could not be saved. Stay on the same Wi-Fi.')),
    );
  }
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
