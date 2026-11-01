import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as im;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Stable across launches. [String.hashCode] is not.
String _stableHash(String value) {
  var hash = 2166136261;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 16777619) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16);
}

String _faceStem(String name) {
  final lower = name.trim().toLowerCase();
  final clean = lower.replaceAll(RegExp(r'[^a-z0-9_-]'), '');
  final who = clean.isEmpty ? 'user' : clean;
  return 'chat-face-$who-${_stableHash(lower)}';
}

String _faceFileName(String name, int rev) => '${_faceStem(name)}-$rev.bin';

Future<Directory> _faceDir() async {
  final root = await getApplicationSupportDirectory();
  final dir = Directory(p.join(root.path, 'chat-faces'));
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

/// Keeps a sender photo on this device for the next notification.
Future<void> storeNotificationPhoto(String name, int rev, Uint8List bytes) async {
  if (name.trim().isEmpty || bytes.isEmpty || rev < 0) return;
  final dir = await _faceDir();
  final file = File(p.join(dir.path, _faceFileName(name, rev)));
  await file.writeAsBytes(bytes, flush: true);
}

/// A sender photo saved the last time this chat was opened.
///
/// [exact] is true when the file is this revision, not an older one.
Future<({Uint8List? bytes, bool exact})> loadNotificationPhoto(
  String name,
  int rev,
) async {
  if (name.trim().isEmpty) return (bytes: null, exact: false);
  final dir = await _faceDir();
  if (rev > 0) {
    final exact = File(p.join(dir.path, _faceFileName(name, rev)));
    if (exact.existsSync()) {
      final bytes = await exact.readAsBytes();
      if (bytes.isNotEmpty) return (bytes: bytes, exact: true);
    }
  }
  final latest = await _latestFace(dir, name);
  return (bytes: latest, exact: false);
}

Future<Uint8List?> _latestFace(Directory dir, String name) async {
  final prefix = '${_faceStem(name)}-';
  File? best;
  var bestRev = -1;
  await for (final entity in dir.list()) {
    if (entity is! File) continue;
    final base = p.basename(entity.path);
    if (!base.startsWith(prefix) || !base.endsWith('.bin')) continue;
    final rev = int.tryParse(base.substring(prefix.length, base.length - 4));
    if (rev == null || rev < bestRev) continue;
    bestRev = rev;
    best = entity;
  }
  if (best == null) return null;
  final bytes = await best.readAsBytes();
  return bytes.isEmpty ? null : bytes;
}

String _extOf(Uint8List bytes) {
  final png = bytes.length >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50;
  final jpg = bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8;
  if (png) return 'png';
  if (jpg) return 'jpg';
  return 'img';
}

/// Writes a square PNG a Windows toast can show in the profile circle.
Future<String?> saveNotificationPhoto(Uint8List bytes, String name) async {
  if (bytes.isEmpty) return null;
  var out = bytes;
  var ext = _extOf(bytes);
  try {
    final decoded = im.decodeImage(bytes);
    if (decoded != null) {
      final fitted = im.copyResizeCropSquare(
        decoded,
        size: 192,
        interpolation: im.Interpolation.linear,
      );
      final png = im.encodePng(fitted, level: 6);
      if (png.isNotEmpty) {
        out = png;
        ext = 'png';
      }
    }
  } catch (_) {}
  final dir = await getTemporaryDirectory();
  final file = File(p.join(dir.path, '${_faceStem(name)}.$ext'));
  await file.writeAsBytes(out, flush: true);
  return file.absolute.path;
}
