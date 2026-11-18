import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-chat wallpaper. The app default stays the global pattern.
class ChatWalls {
  ChatWalls._();

  static const modeDefault = 'default';
  static const modePattern = 'pattern';
  static const modePlain = 'plain';
  static const modePhoto = 'photo';

  static const _key = 'chat.wall.mode.v1';

  static Future<String> mode(String threadId) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('$_key.$threadId') ?? modeDefault;
    if (stored == modePattern || stored == modePlain || stored == modePhoto) return stored;
    return modeDefault;
  }

  static Future<void> setMode(String threadId, String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_key.$threadId', mode);
  }

  static Future<void> savePhoto(String threadId, Uint8List bytes) async {
    if (kIsWeb) return;
    final file = await _file(threadId);
    if (file == null) return;
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    await setMode(threadId, modePhoto);
  }

  static Future<Uint8List?> photo(String threadId) async {
    if (kIsWeb) return null;
    final file = await _file(threadId);
    if (file == null || !await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    return bytes;
  }

  static Future<File?> _file(String threadId) async {
    final clean = threadId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    if (clean.isEmpty) return null;
    final root = await getApplicationSupportDirectory();
    return File(p.join(root.path, 'chat-walls', '$clean.jpg'));
  }
}
