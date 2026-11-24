import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
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

  Directory? _cachedDir;

  /// Where vault videos live. On Windows this was Documents\vault, which
  /// OneDrive can sync and anyone browsing Documents can open; it is now the
  /// app's own data folder, and old files are moved there safely once.
  Future<Directory> _dir() async {
    final cached = _cachedDir;
    if (cached != null && await cached.exists()) return cached;
    final Directory dir;
    if (Platform.isWindows) {
      final support = await getApplicationSupportDirectory();
      dir = Directory(p.join(support.path, 'vault'));
      if (!await dir.exists()) await dir.create(recursive: true);
      try {
        final docs = await getApplicationDocumentsDirectory();
        await migrateVaultFolder(Directory(p.join(docs.path, 'vault')), dir);
      } catch (_) {
        // A failed move leaves every old file where it was; it is tried
        // again next time.
      }
    } else {
      final docs = await getApplicationDocumentsDirectory();
      dir = Directory(p.join(docs.path, 'vault'));
      if (!await dir.exists()) await dir.create(recursive: true);
    }
    final nomedia = File(p.join(dir.path, '.nomedia'));
    if (!await nomedia.exists()) {
      await nomedia.create();
    }
    _cachedDir = dir;
    return dir;
  }

  Future<List<VaultItem>> list() async {
    final dir = await _dir();
    return _guard(() => readVaultIndex(dir));
  }

  /// Vault changes run one at a time, so two quick actions never write the
  /// list over each other.
  static Future<void> _queue = Future<void>.value();

  static Future<T> _guard<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  // ---- PIN attempts ----

  static const _failsKey = 'vault.pin.fails';
  static const _lockedUntilKey = 'vault.pin.lockedUntil';

  /// The wait after [fails] wrong PINs in a row. The first four are free;
  /// then 30 s, 1 min, 5 min, 15 min, and 1 hour for every try after that.
  /// Nothing is ever wiped.
  static Duration lockoutFor(int fails) {
    if (fails < 5) return Duration.zero;
    const steps = [
      Duration(seconds: 30),
      Duration(minutes: 1),
      Duration(minutes: 5),
      Duration(minutes: 15),
      Duration(hours: 1),
    ];
    final i = fails - 5;
    return steps[i < steps.length ? i : steps.length - 1];
  }

  /// How long until the next PIN try is allowed.
  Duration lockedFor([DateTime? now]) {
    final until = _prefs.getInt(_lockedUntilKey) ?? 0;
    final left = until - (now ?? DateTime.now()).millisecondsSinceEpoch;
    return left > 0 ? Duration(milliseconds: left) : Duration.zero;
  }

  /// Checks a PIN and counts wrong tries. A locked vault refuses every try
  /// (right or wrong) until the wait is over.
  Future<VaultPinCheck> checkPin(String pin, {DateTime? now}) async {
    final at = now ?? DateTime.now();
    final wait = lockedFor(at);
    if (wait > Duration.zero) return VaultPinCheck(ok: false, wait: wait);
    if (verifyPin(pin)) {
      await _prefs.remove(_failsKey);
      await _prefs.remove(_lockedUntilKey);
      return const VaultPinCheck(ok: true);
    }
    final fails = (_prefs.getInt(_failsKey) ?? 0) + 1;
    await _prefs.setInt(_failsKey, fails);
    final next = lockoutFor(fails);
    if (next > Duration.zero) {
      await _prefs.setInt(_lockedUntilKey, at.add(next).millisecondsSinceEpoch);
    }
    return VaultPinCheck(ok: false, wait: next);
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
    await _prefs.remove(_failsKey);
    await _prefs.remove(_lockedUntilKey);
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
    await _guard(() async {
      final dir = await _dir();
      final items = await readVaultIndex(dir);
      // The copied file may already show up as an unlisted video.
      items.removeWhere((entry) => entry.fileName == fileName);
      items.insert(0, item);
      await writeVaultIndex(dir, items);
    });
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
    await _guard(() async {
      final dir = await _dir();
      final items = await readVaultIndex(dir);
      final index = items.indexWhere((entry) => entry.id == item.id);
      if (index < 0) return;
      items[index] = VaultItem(
        id: item.id,
        title: cleaned,
        fileName: item.fileName,
        bytes: item.bytes,
        addedAt: item.addedAt,
      );
      await writeVaultIndex(dir, items);
    });
  }

  Future<void> delete(VaultItem item) async {
    final file = await fileFor(item);
    if (await file.exists()) {
      await file.delete();
    }
    await _guard(() async {
      final dir = await _dir();
      final items = await readVaultIndex(dir);
      items.removeWhere((entry) => entry.id == item.id);
      await writeVaultIndex(dir, items);
    });
  }
}

/// Result of one PIN try. [wait] is how long the next try must wait.
class VaultPinCheck {
  const VaultPinCheck({required this.ok, this.wait = Duration.zero});

  final bool ok;
  final Duration wait;
}

final _vaultFileName = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[A-Za-z0-9]{1,5}$');

List<VaultItem>? _parseIndex(String text) {
  try {
    final raw = jsonDecode(text);
    if (raw is! List) return null;
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map((item) => VaultItem.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  } catch (_) {
    return null;
  }
}

/// Reads the vault list. A damaged list falls back to the backup copy, and
/// if both are gone the list is rebuilt from the video files themselves, so
/// a crash while saving can never make vault videos disappear.
@visibleForTesting
Future<List<VaultItem>> readVaultIndex(Directory dir) async {
  final index = File(p.join(dir.path, 'index.json'));
  final backup = File(p.join(dir.path, 'index.json.bak'));
  for (final file in [index, backup]) {
    if (!await file.exists()) continue;
    final items = _parseIndex(await file.readAsString());
    if (items != null) {
      return _withLooseFiles(dir, items)..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    }
  }
  final rebuilt = _withLooseFiles(dir, <VaultItem>[]);
  if (rebuilt.isNotEmpty) await writeVaultIndex(dir, rebuilt);
  return rebuilt..sort((a, b) => b.addedAt.compareTo(a.addedAt));
}

/// Adds vault videos that are on disk but missing from [items].
List<VaultItem> _withLooseFiles(Directory dir, List<VaultItem> items) {
  final known = {for (final item in items) item.fileName};
  final out = List<VaultItem>.of(items);
  if (!dir.existsSync()) return out;
  for (final entity in dir.listSync()) {
    if (entity is! File) continue;
    final name = p.basename(entity.path);
    if (!_vaultFileName.hasMatch(name) || known.contains(name)) continue;
    out.add(VaultItem(
      id: name.substring(0, 36),
      title: 'Video',
      fileName: name,
      bytes: entity.lengthSync(),
      addedAt: entity.lastModifiedSync(),
    ));
  }
  return out;
}

/// Saves the vault list safely: write a new file, keep the old one as a
/// backup, then swap. A crash at any point leaves a readable list.
@visibleForTesting
Future<void> writeVaultIndex(Directory dir, List<VaultItem> items) async {
  final index = File(p.join(dir.path, 'index.json'));
  final temp = File(p.join(dir.path, 'index.json.tmp'));
  final backup = File(p.join(dir.path, 'index.json.bak'));
  await temp.writeAsString(jsonEncode(items.map((item) => item.toJson()).toList()), flush: true);
  if (await index.exists() && _parseIndex(await index.readAsString()) != null) {
    await index.copy(backup.path);
  }
  try {
    await temp.rename(index.path);
  } on FileSystemException {
    if (await index.exists()) await index.delete();
    await temp.rename(index.path);
  }
}

Future<bool> _sameBytes(File a, File b) async {
  if (await a.length() != await b.length()) return false;
  final ra = await a.open();
  final rb = await b.open();
  try {
    while (true) {
      final x = await ra.read(1 << 20);
      final y = await rb.read(1 << 20);
      if (x.length != y.length) return false;
      if (x.isEmpty) return true;
      for (var i = 0; i < x.length; i++) {
        if (x[i] != y[i]) return false;
      }
    }
  } finally {
    await ra.close();
    await rb.close();
  }
}

/// Moves vault videos from [from] to [to]. Each video is copied, checked
/// byte for byte, and listed in the new vault before the old copy is
/// removed. Only files the vault itself made are touched, so a folder the
/// person named "vault" keeps its own files.
@visibleForTesting
Future<int> migrateVaultFolder(Directory from, Directory to) async {
  if (!await from.exists()) return 0;
  if (p.equals(from.absolute.path, to.absolute.path)) return 0;
  final oldItems = await readVaultIndex(from);
  if (oldItems.isEmpty) return 0;
  if (!await to.exists()) await to.create(recursive: true);
  final newItems = await readVaultIndex(to);
  final moved = <VaultItem>[];
  final left = <VaultItem>[];
  for (final item in oldItems) {
    final source = File(p.join(from.path, item.fileName));
    if (!_vaultFileName.hasMatch(item.fileName) || !await source.exists()) {
      left.add(item);
      continue;
    }
    final dest = File(p.join(to.path, item.fileName));
    try {
      if (!await dest.exists() || !await _sameBytes(source, dest)) {
        final temp = File('${dest.path}.part');
        await source.copy(temp.path);
        if (!await _sameBytes(source, temp)) {
          await temp.delete();
          left.add(item);
          continue;
        }
        if (await dest.exists()) await dest.delete();
        await temp.rename(dest.path);
      }
      moved.add(item);
    } catch (_) {
      left.add(item);
    }
  }
  if (moved.isEmpty) return 0;
  final have = {for (final item in newItems) item.id};
  await writeVaultIndex(to, [
    ...newItems,
    for (final item in moved)
      if (!have.contains(item.id)) item,
  ]);
  // Only now, with every moved video listed in the new vault, remove the
  // old copies.
  for (final item in moved) {
    try {
      await File(p.join(from.path, item.fileName)).delete();
    } catch (_) {}
  }
  if (left.isEmpty) {
    for (final name in ['index.json', 'index.json.bak', 'index.json.tmp', '.nomedia']) {
      final f = File(p.join(from.path, name));
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    try {
      if (from.listSync().isEmpty) await from.delete();
    } catch (_) {}
  } else {
    await writeVaultIndex(from, left);
  }
  return moved.length;
}
