import 'dart:convert';
import 'dart:io';

import 'package:hive/hive.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/downloads/domain/repositories/downloads_repository.dart';

class HiveDownloadHistoryStore implements DownloadsRepository {
  HiveDownloadHistoryStore(this._box);

  final Box<String> _box;

  @override
  Future<List<DownloadRecord>> getAll() async {
    final records = _box.values
        .map(_decode)
        .whereType<DownloadRecord>()
        .toList()
      ..sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
    return records;
  }

  @override
  Future<DownloadRecord?> getById(String id) async {
    final raw = _box.get(id);
    if (raw == null) {
      return null;
    }
    return _decode(raw);
  }

  @override
  Future<void> upsert(DownloadRecord record) async {
    await _box.put(record.id, jsonEncode(record.toJson()));
  }

  @override
  Future<void> delete(String id, {bool deleteFile = false}) async {
    if (deleteFile) {
      final existing = await getById(id);
      await _deleteFile(existing?.localPath);
    }
    await _box.delete(id);
  }

  @override
  Future<void> clear({bool deleteFiles = false}) async {
    if (deleteFiles) {
      final records = await getAll();
      for (final record in records) {
        await _deleteFile(record.localPath);
      }
    }
    await _box.clear();
  }

  @override
  Stream<List<DownloadRecord>> watch() async* {
    yield await getAll();
    yield* _box.watch().asyncMap((_) => getAll());
  }

  DownloadRecord? _decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) {
        return DownloadRecord.fromJson(json);
      }
      if (json is Map) {
        return DownloadRecord.fromJson(Map<String, dynamic>.from(json));
      }
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _deleteFile(String? path) async {
    if (path == null || path.isEmpty) {
      return;
    }
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

class InMemoryDownloadHistoryStore implements DownloadsRepository {
  final Map<String, DownloadRecord> _records = {};

  @override
  Future<List<DownloadRecord>> getAll() async {
    return _records.values.toList()
      ..sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
  }

  @override
  Future<DownloadRecord?> getById(String id) async => _records[id];

  @override
  Future<void> upsert(DownloadRecord record) async {
    _records[record.id] = record;
  }

  @override
  Future<void> delete(String id, {bool deleteFile = false}) async {
    _records.remove(id);
  }

  @override
  Future<void> clear({bool deleteFiles = false}) async {
    _records.clear();
  }

  @override
  Stream<List<DownloadRecord>> watch() async* {
    yield await getAll();
  }
}
