import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/downloads/presentation/providers/downloads_controller.dart';
import 'package:social_save/features/library/library_catalog.dart';
import 'package:social_save/shared/models/download_status.dart';
import 'package:social_save/shared/models/social_platform.dart';

/// The library list shared with a connected phone or computer.
/// Files stay where they were saved. The other screen gets the titles.
class LibrarySync {
  LibrarySync._();

  static const idPrefix = 'sync:';
  static ProviderContainer? Function()? containerOf;

  static String idFor(String url) {
    final digest = sha1.convert(utf8.encode(url.trim())).toString();
    return '$idPrefix${digest.substring(0, 16)}';
  }

  /// True when the other device answered. A miss means the caller should try again.
  static Future<bool> exchange(String host, int port, String token) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.postUrl(Uri.http('$host:$port', '/session/library'));
      req.headers.contentType = ContentType.json;
      final local = await payload();
      local['token'] = token;
      req.write(jsonEncode(local));
      final res = await req.close().timeout(const Duration(seconds: 20));
      final text = await utf8.decoder.bind(res).join();
      if (res.statusCode == HttpStatus.notFound) return true;
      if (res.statusCode != HttpStatus.ok) return false;
      final data = jsonDecode(text);
      if (data is Map) await merge(Map<String, dynamic>.from(data));
      return true;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Stores what the other device sent and returns this device's list.
  static Future<Map<String, dynamic>> accept(Map<String, dynamic> body) async {
    final ours = await payload();
    await merge(body);
    return ours;
  }

  static Future<Map<String, dynamic>> payload() async {
    final records = await _records();
    final items = <Map<String, dynamic>>[];
    for (final record in records) {
      if (record.sourceUrl.trim().isEmpty) continue;
      if (items.length >= 200) break;
      final thumb = record.thumbnailUrl;
      items.add({
        'title': record.title,
        'sourceUrl': record.sourceUrl,
        'platform': record.platform.id,
        'author': record.author,
        'thumbnailUrl': thumb != null && thumb.length <= 400 ? thumb : null,
        'downloadedAt': record.downloadedAt.toIso8601String(),
        'quality': record.quality,
      });
    }
    final later = await _later();
    return {
      'ok': true,
      'items': items,
      'later': [for (final item in later.take(100)) item.toJson()],
    };
  }

  static Future<void> merge(Map<String, dynamic> body) async {
    final incoming = body['items'];
    if (incoming is List) {
      final mine = await _records();
      final have = {for (final record in mine) record.sourceUrl};
      for (final raw in incoming) {
        if (raw is! Map) continue;
        final url = '${raw['sourceUrl'] ?? ''}'.trim();
        if (url.isEmpty || have.contains(url)) continue;
        final title = '${raw['title'] ?? ''}'.trim();
        final record = DownloadRecord(
          id: idFor(url),
          title: title.isEmpty ? 'Video' : title,
          sourceUrl: url,
          platform: SocialPlatform.fromId('${raw['platform'] ?? ''}'),
          downloadedAt: DateTime.tryParse('${raw['downloadedAt'] ?? ''}') ?? DateTime.now(),
          status: DownloadStatus.completed,
          thumbnailUrl: raw['thumbnailUrl'] is String ? raw['thumbnailUrl'] as String : null,
          author: ('${raw['author'] ?? ''}').trim().isEmpty ? null : '${raw['author']}'.trim(),
          quality: raw['quality'] is String ? raw['quality'] as String : null,
        );
        await _put(record);
        have.add(url);
      }
    }
    final later = body['later'];
    if (later is List) {
      final container = containerOf?.call();
      final known = {for (final record in await _records()) record.sourceUrl};
      for (final raw in later) {
        if (raw is! Map) continue;
        final item = WatchLaterItem.fromJson(raw);
        if (item.url.isEmpty || known.contains(item.url)) continue;
        if (container != null) {
          await container.read(libraryCatalogProvider.notifier).addLater(item);
        }
      }
    }
    containerOf?.call()?.invalidate(downloadsControllerProvider);
  }

  static Future<List<DownloadRecord>> _records() async {
    final container = containerOf?.call();
    if (container != null) {
      return container.read(downloadsRepositoryProvider).getAll();
    }
    if (!Hive.isBoxOpen(AppConstants.downloadsBoxName)) return const [];
    final box = Hive.box<String>(AppConstants.downloadsBoxName);
    final records = <DownloadRecord>[];
    for (final raw in box.values) {
      try {
        final json = jsonDecode(raw);
        if (json is Map) records.add(DownloadRecord.fromJson(Map<String, dynamic>.from(json)));
      } catch (_) {}
    }
    records.sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
    return records;
  }

  static Future<void> _put(DownloadRecord record) async {
    final container = containerOf?.call();
    if (container != null) {
      await container.read(downloadsRepositoryProvider).upsert(record);
      return;
    }
    if (!Hive.isBoxOpen(AppConstants.downloadsBoxName)) return;
    await Hive.box<String>(AppConstants.downloadsBoxName).put(record.id, jsonEncode(record.toJson()));
  }

  static Future<List<WatchLaterItem>> _later() async {
    final container = containerOf?.call();
    if (container != null) return container.read(libraryCatalogProvider).later;
    final prefs = await SharedPreferences.getInstance();
    return LibraryCatalog.decode(prefs.getString('socialsave_library_catalog') ?? '').later;
  }
}
