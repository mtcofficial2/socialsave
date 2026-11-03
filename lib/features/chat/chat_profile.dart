import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as im;
import 'package:flutter/services.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/features/chat/chat_thread_screen.dart';

/// The person behind a username. Another person's phone or email is never shown.
Future<void> showChatProfile(
  BuildContext context, {
  required String username,
  String contact = '',
  int photoRev = 0,
  DateTime? lastSeen,
  bool online = false,
  void Function(int photoRev)? onPhoto,
  void Function()? onLogOut,
}) {
  final name = username.replaceFirst(RegExp(r'^@'), '').trim();
  final mine = contact.trim().isNotEmpty;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      var rev = photoRev;
      var busy = false;
      String? problem;
      final presence = chatPresenceLabel(
        lastSeen,
        online,
        DateTime.now(),
        lastSeen == null
            ? ''
            : TimeOfDay.fromDateTime(lastSeen.toLocal()).format(context),
      );
      return StatefulBuilder(
        builder: (context, setSheet) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ChatFace(
                    name: name.isEmpty ? '?' : name,
                    size: 96,
                    photoRev: rev,
                    online: !mine && online,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    name.isEmpty ? 'Chat' : name,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                  if (!mine && presence.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      presence,
                      style: TextStyle(
                        color: online
                            ? const Color(0xFF25D366)
                            : scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    mine
                        ? 'This is your Social Save profile'
                        : 'Social Save profile',
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                  if (mine) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Registered with ${contact.trim()}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  if (mine)
                    FilledButton.tonalIcon(
                      onPressed: busy
                          ? null
                          : () async {
                              setSheet(() {
                                busy = true;
                                problem = null;
                              });
                              try {
                                final next = await _pickChatPhoto(name);
                                if (!context.mounted) return;
                                if (next != null) {
                                  rev = next;
                                  onPhoto?.call(next);
                                }
                                setSheet(() => busy = false);
                              } catch (error) {
                                if (!context.mounted) return;
                                setSheet(() {
                                  busy = false;
                                  problem = error is StateError
                                      ? 'Choose a JPEG or PNG photo.'
                                      : chatErrorText(error);
                                });
                              }
                            },
                      icon: busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.photo_camera_rounded),
                      label: const Text('Change photo'),
                    ),
                  if (mine) const SizedBox(height: 8),
                  if (mine && onLogOut != null) ...[
                    TextButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        onLogOut();
                      },
                      icon: Icon(Icons.logout_rounded, color: scheme.error),
                      label: Text(
                        'Log out',
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: '@$name'));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Username copied')),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded),
                    label: const Text('Copy username'),
                  ),
                  if (problem != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      problem!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.error, height: 1.35),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

Future<int?> _pickChatPhoto(String username) async {
  final picked = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Photos', extensions: ['jpg', 'jpeg', 'png']),
    ],
  );
  if (picked == null) return null;
  final raw = await picked.readAsBytes();
  final fitted = await fitChatPhoto(raw);
  final rev = await ChatApi().setPhoto(fitted);
  ChatPhotos.remember(username, rev, fitted);
  return rev;
}

bool _jpegOrPng(Uint8List raw) {
  if (raw.length >= 3 && raw[0] == 0xFF && raw[1] == 0xD8 && raw[2] == 0xFF) {
    return true;
  }
  return raw.length >= 8 &&
      raw[0] == 0x89 &&
      raw[1] == 0x50 &&
      raw[2] == 0x4E &&
      raw[3] == 0x47;
}

Uint8List _fitChatJpeg(Uint8List raw) {
  final decoded = im.decodeImage(raw);
  if (decoded == null) throw StateError('Choose a JPEG or PNG photo.');
  var current = decoded;
  for (final width in [1280, 960, 640, 480]) {
    if (current.width > width) current = im.copyResize(current, width: width);
    final jpg = Uint8List.fromList(im.encodeJpg(current, quality: 74));
    if (jpg.length <= 512 * 1024) return jpg;
  }
  throw StateError('Choose a JPEG or PNG photo.');
}

/// A conversation photo, small enough to hand to the other phone.
Future<Uint8List> fitChatImage(Uint8List raw) async {
  if (raw.length <= 512 * 1024 && _jpegOrPng(raw)) return raw;
  try {
    return await compute(_fitChatJpeg, raw);
  } catch (error) {
    if (error is StateError) rethrow;
  }
  Object? last;
  for (final width in [1280, 960, 640, 256]) {
    try {
      final codec = await ui.instantiateImageCodec(raw, targetWidth: width);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      if (data == null) continue;
      final bytes = data.buffer.asUint8List();
      if (bytes.length <= 512 * 1024) return bytes;
    } catch (error) {
      last = error;
    }
  }
  throw last ?? StateError('Choose a JPEG or PNG photo.');
}

/// A small PNG the chat server will accept.
Future<Uint8List> fitChatPhoto(Uint8List raw) async {
  Object? last;
  for (final width in [256, 160, 96]) {
    try {
      final codec = await ui.instantiateImageCodec(raw, targetWidth: width);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      if (data == null) continue;
      final bytes = data.buffer.asUint8List();
      if (bytes.length <= 512 * 1024) return bytes;
    } catch (error) {
      last = error;
    }
  }
  throw last ?? StateError('Choose a JPEG or PNG photo.');
}
