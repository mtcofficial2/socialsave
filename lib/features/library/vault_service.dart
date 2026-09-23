import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/storage/media_store_service.dart';
import 'package:social_save/core/utils/file_utils.dart';
import 'package:uuid/uuid.dart';

class VaultItem {
  const VaultItem({
    required this.id,
    required this.title,
    required this.fileName,
    required this.bytes,
    required this.addedAt,
  });

  final String id;
  final String title;
  final String fileName;
  final int bytes;
  final DateTime addedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'fileName': fileName,
        'bytes': bytes,
        'addedAt': addedAt.toIso8601String(),
      };

  factory VaultItem.fromJson(Map<String, dynamic> json) {
    return VaultItem(
      id: json['id'] as String,
      title: json['title'] as String? ?? 'Video',
      fileName: json['fileName'] as String,
      bytes: json['bytes'] as int? ?? 0,
      addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

class VaultService {
  VaultService(this._prefs);

  final SharedPreferences _prefs;
  static const _hashKey = 'vault.pin.hash';
  static const _saltKey = 'vault.pin.salt';
  static const _uuid = Uuid();

  bool get hasPin => (_prefs.getString(_hashKey) ?? '').isNotEmpty;

  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'vault'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final nomedia = File(p.join(dir.path, '.nomedia'));
    if (!await nomedia.exists()) {
      await nomedia.create();
    }
    return dir;
  }

  Future<File> _indexFile() async {
    return File(p.join((await _dir()).path, 'index.json'));
  }

  Future<List<VaultItem>> list() async {
    final file = await _indexFile();
    if (!await file.exists()) return [];
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return [];
      return raw
          .whereType<Map<dynamic, dynamic>>()
          .map((item) => VaultItem.fromJson(Map<String, dynamic>.from(item)))
          .toList()
        ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeIndex(List<VaultItem> items) async {
    final file = await _indexFile();
    await file.writeAsString(
      jsonEncode(items.map((item) => item.toJson()).toList()),
    );
  }

  String _hash(String pin, String salt) {
    return sha256.convert(utf8.encode('$salt::$pin')).toString();
  }

  Future<void> setPin(String pin) async {
    final salt = List.generate(16, (_) => Random.secure().nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    await _prefs.setString(_saltKey, salt);
    await _prefs.setString(_hashKey, _hash(pin, salt));
  }

  bool verifyPin(String pin) {
    final salt = _prefs.getString(_saltKey) ?? '';
    final expected = _prefs.getString(_hashKey) ?? '';
    if (salt.isEmpty || expected.isEmpty) return false;
    return _hash(pin, salt) == expected;
  }

  Future<File> fileFor(VaultItem item) async {
    return File(p.join((await _dir()).path, item.fileName));
  }

  String publicFileName(VaultItem item) {
    final ext = p.extension(item.fileName).replaceFirst('.', '');
    return const FileUtils().buildFileName(
      title: item.title,
      format: ext.isEmpty ? 'mp4' : ext,
    );
  }

  String mimeType(VaultItem item) {
    switch (p.extension(item.fileName).toLowerCase()) {
      case '.webm':
        return 'video/webm';
      case '.mov':
        return 'video/quicktime';
      case '.m4v':
        return 'video/x-m4v';
      case '.mkv':
        return 'video/x-matroska';
      default:
        return 'video/mp4';
    }
  }

  Future<VaultItem> importFile({
    required String sourcePath,
    required String title,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw StateError('Source video is missing.');
    }
    final id = _uuid.v4();
    final ext = p.extension(sourcePath).isEmpty ? '.mp4' : p.extension(sourcePath);
    final fileName = '$id$ext';
    final dest = File(p.join((await _dir()).path, fileName));
    await source.copy(dest.path);
    final item = VaultItem(
      id: id,
      title: title,
      fileName: fileName,
      bytes: await dest.length(),
      addedAt: DateTime.now(),
    );
    final items = await list();
    items.insert(0, item);
    await _writeIndex(items);
    return item;
  }

  Future<String> restoreToGallery(VaultItem item) async {
    final file = await fileFor(item);
    if (!await file.exists()) {
      throw StateError('This vault file is missing.');
    }
    final published = await MediaStoreService().publishToGallery(
      sourcePath: file.path,
      fileName: publicFileName(item),
      mimeType: mimeType(item),
    );
    if (published == null || published.isEmpty) {
      throw StateError('Could not restore this video to Gallery.');
    }
    return published;
  }

  Future<void> rename(VaultItem item, String title) async {
    final cleaned = title.trim();
    if (cleaned.isEmpty) return;
    final items = await list();
    final index = items.indexWhere((entry) => entry.id == item.id);
    if (index < 0) return;
    items[index] = VaultItem(
      id: item.id,
      title: cleaned,
      fileName: item.fileName,
      bytes: item.bytes,
      addedAt: item.addedAt,
    );
    await _writeIndex(items);
  }

  Future<void> delete(VaultItem item) async {
    final file = await fileFor(item);
    if (await file.exists()) {
      await file.delete();
    }
    final items = await list();
    items.removeWhere((entry) => entry.id == item.id);
    await _writeIndex(items);
  }
}
