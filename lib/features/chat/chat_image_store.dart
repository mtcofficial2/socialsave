import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A picture in a chat, kept on this device only.
class ChatImageStore {
  static final revision = ValueNotifier<int>(0);
  static const _pendingKey = 'chat.photos.pending.v1';

  static bool _safe(String id) => RegExp(r'^[a-z0-9]+$').hasMatch(id);

  static Future<Directory> _dir() async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(root.path, 'chat-images'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<void> save(String id, Uint8List bytes) async {
    if (!_safe(id) || bytes.isEmpty) return;
    final dir = await _dir();
    await File(p.join(dir.path, id)).writeAsBytes(bytes, flush: true);
    revision.value++;
  }

  static Future<Uint8List?> load(String id) async {
    if (!_safe(id)) return null;
    final file = File(p.join((await _dir()).path, id));
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    return bytes;
  }

  static Future<void> keep(String threadId, String id) async {
    if (threadId.isEmpty || !_safe(id)) return;
    final prefs = await SharedPreferences.getInstance();
    final items = _read(prefs)..removeWhere((item) => item.id == id);
    items.add(_PendingPhoto(threadId, id));
    await _write(prefs, items);
  }

  static Future<void> clear(String id) async {
    if (!_safe(id)) return;
    final prefs = await SharedPreferences.getInstance();
    await _write(prefs, _read(prefs).where((item) => item.id != id).toList());
  }

  static Future<void> flush(void Function(Uint8List frame) send) async {
    final prefs = await SharedPreferences.getInstance();
    for (final item in _read(prefs)) {
      await sendPending(item.id, send);
    }
  }

  static Future<void> sendPending(
    String id,
    void Function(Uint8List frame) send,
  ) async {
    if (!_safe(id)) return;
    final prefs = await SharedPreferences.getInstance();
    _PendingPhoto? item;
    for (final pending in _read(prefs)) {
      if (pending.id == id) {
        item = pending;
        break;
      }
    }
    if (item == null) return;
    final bytes = await load(id);
    if (bytes == null) return;
    send(encodeChatPhotoFrame(item.threadId, item.id, bytes));
  }

  static Future<void> take(
    Uint8List payload,
    void Function(String text) reply,
  ) async {
    final frame = decodeChatPhotoFrame(payload);
    if (frame == null) return;
    await save(frame.id, frame.bytes);
    reply(
      jsonEncode({
        'type': 'photo-have',
        'thread': frame.threadId,
        'id': frame.id,
      }),
    );
  }

  static List<_PendingPhoto> _read(SharedPreferences prefs) {
    final raw = prefs.getString(_pendingKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final data = jsonDecode(raw);
      if (data is! List) return [];
      return [
        for (final item in data)
          if (item is Map && item['thread'] is String && item['id'] is String)
            _PendingPhoto(item['thread'] as String, item['id'] as String),
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> _write(
    SharedPreferences prefs,
    List<_PendingPhoto> items,
  ) {
    return prefs.setString(
      _pendingKey,
      jsonEncode([
        for (final item in items) {'thread': item.threadId, 'id': item.id},
      ]),
    );
  }
}

class _PendingPhoto {
  const _PendingPhoto(this.threadId, this.id);
  final String threadId;
  final String id;
}

class DecodedChatPhoto {
  const DecodedChatPhoto(this.threadId, this.id, this.bytes);
  final String threadId;
  final String id;
  final Uint8List bytes;
}

Uint8List encodeChatPhotoFrame(
  String threadId,
  String photoId,
  Uint8List body,
) {
  final thread = utf8.encode(threadId);
  final photo = utf8.encode(photoId);
  final out = Uint8List(1 + 2 + thread.length + 2 + photo.length + body.length);
  var i = 0;
  out[i++] = 1;
  out[i++] = (thread.length >> 8) & 0xff;
  out[i++] = thread.length & 0xff;
  out.setRange(i, i + thread.length, thread);
  i += thread.length;
  out[i++] = (photo.length >> 8) & 0xff;
  out[i++] = photo.length & 0xff;
  out.setRange(i, i + photo.length, photo);
  i += photo.length;
  out.setRange(i, i + body.length, body);
  return out;
}

DecodedChatPhoto? decodeChatPhotoFrame(Uint8List payload) {
  if (payload.length < 5 || payload[0] != 1) return null;
  final threadLen = (payload[1] << 8) | payload[2];
  if (threadLen < 1 || threadLen > 40 || payload.length < 3 + threadLen + 2) {
    return null;
  }
  final threadId = utf8.decode(
    payload.sublist(3, 3 + threadLen),
    allowMalformed: false,
  );
  var off = 3 + threadLen;
  final photoLen = (payload[off] << 8) | payload[off + 1];
  off += 2;
  if (photoLen < 1 || photoLen > 40 || payload.length <= off + photoLen) {
    return null;
  }
  final id = utf8.decode(
    payload.sublist(off, off + photoLen),
    allowMalformed: false,
  );
  final bytes = Uint8List.sublistView(payload, off + photoLen);
  if (bytes.isEmpty) return null;
  return DecodedChatPhoto(threadId, id, bytes);
}
