import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/core/platform/media_events.dart';
import 'package:social_save/core/utils/platform_detector.dart';
import 'package:social_save/core/utils/set_link.dart';
import 'package:social_save/features/downloader/presentation/providers/download_manager.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';
import 'package:social_save/shared/models/media_format.dart';
import 'package:social_save/shared/models/social_platform.dart';

/// One public YouTube channel or playlist, or one TikTok profile, checked overnight.
class FollowedSet {
  const FollowedSet({
    required this.url,
    required this.title,
    required this.seen,
    this.lastCheck,
  });

  final String url;
  final String title;
  final List<String> seen;
  final DateTime? lastCheck;

  FollowedSet copyWith({List<String>? seen, DateTime? lastCheck}) {
    return FollowedSet(url: url, title: title, seen: seen ?? this.seen, lastCheck: lastCheck ?? this.lastCheck);
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        'seen': seen,
        'lastCheck': lastCheck?.toIso8601String(),
      };

  factory FollowedSet.fromJson(Map<dynamic, dynamic> json) {
    final seen = <String>[];
    final raw = json['seen'];
    if (raw is List) {
      for (final item in raw) {
        final url = '$item'.trim();
        if (url.isNotEmpty) seen.add(url);
      }
    }
    return FollowedSet(
      url: '${json['url'] ?? ''}'.trim(),
      title: '${json['title'] ?? ''}'.trim().isEmpty ? 'Set' : '${json['title'] ?? ''}'.trim(),
      seen: seen,
      lastCheck: DateTime.tryParse('${json['lastCheck'] ?? ''}'),
    );
  }
}

/// Public posts that were not in [seen].
List<String> unseenUrls(List<String> current, List<String> seen) {
  final known = seen.toSet();
  final next = <String>[];
  for (final url in current) {
    final trimmed = url.trim();
    if (trimmed.isEmpty || known.contains(trimmed) || next.contains(trimmed)) continue;
    next.add(trimmed);
  }
  return next;
}

/// A YouTube playlist or channel, or a TikTok profile. Login pages are not included.
bool canFollowSet(String url) {
  if (!isPublicSet(url)) return false;
  final platform = const PlatformDetector().detect(url);
  return platform == SocialPlatform.youtube || platform == SocialPlatform.tiktok;
}

/// Remembers a public set and queues only posts that appear after this moment.
class FollowCreator {
  FollowCreator._();

  static const prefKey = 'socialsave_follows';
  static const maxNew = 8;

  static Future<List<FollowedSet>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(prefKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final data = jsonDecode(raw);
      if (data is! List) return const [];
      return [
        for (final item in data)
          if (item is Map) FollowedSet.fromJson(item),
      ].where((item) => item.url.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<void> _save(List<FollowedSet> sets) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefKey, jsonEncode([for (final item in sets) item.toJson()]));
    await _arm(sets.isNotEmpty);
  }

  static Future<void> _arm(bool on) async {
    try {
      await MediaEvents.channel.invokeMethod<void>('scheduleFollow', {'on': on});
    } catch (_) {}
  }

  static Future<bool> isFollowing(String url) async {
    final sets = await load();
    return sets.any((item) => item.url == url.trim());
  }

  /// Marks every post already on the page as seen. Nothing is downloaded yet.
  static Future<void> follow(String url, String title, List<String> currentUrls) async {
    final trimmed = url.trim();
    if (!canFollowSet(trimmed)) return;
    final seen = <String>[];
    for (final item in currentUrls) {
      final one = item.trim();
      if (one.isNotEmpty && !seen.contains(one)) seen.add(one);
    }
    final sets = await load();
    sets.removeWhere((item) => item.url == trimmed);
    sets.add(FollowedSet(
      url: trimmed,
      title: title.trim().isEmpty ? 'Set' : title.trim(),
      seen: seen.length > 500 ? seen.sublist(seen.length - 500) : seen,
      lastCheck: DateTime.now(),
    ));
    await _save(sets);
  }

  static Future<void> unfollow(String url) async {
    final sets = await load();
    sets.removeWhere((item) => item.url == url.trim());
    await _save(sets);
  }

  /// On the next app open, run a check that the overnight alarm missed.
  static Future<void> checkIfDue(ProviderContainer container) async {
    try {
      final sets = await load();
      await _arm(sets.isNotEmpty);
      if (sets.isEmpty) return;
      final due = sets.any((item) {
        final at = item.lastCheck;
        return at == null || DateTime.now().difference(at) > const Duration(hours: 20);
      });
      if (!due) return;
      await run(container);
    } catch (_) {}
  }

  /// Queues new public posts. Private and login-only items are skipped.
  static Future<int> run(ProviderContainer container) async {
    final sets = await load();
    if (sets.isEmpty) return 0;
    var queued = 0;
    final next = <FollowedSet>[];
    for (final set in sets) {
      try {
        final entries = await container.read(mediaRepositoryProvider).playlist(set.url);
        final opened = await expandChannelSections(
          entries,
          (url) => container.read(mediaRepositoryProvider).playlist(url),
          onlyTab: youtubeChannelTab(set.url),
        );
        final onlyTabs = entries.isNotEmpty &&
            entries.every((entry) => isChannelSection(entry.url) || youtubeChannelRoot(entry.url) != null);
        if (opened.isEmpty && onlyTabs) {
          next.add(set);
          continue;
        }
        final current = [for (final entry in opened) entry.url];
        final fresh = unseenUrls(current, set.seen);
        final take = fresh.take(maxNew).toList();
        final seen = [...set.seen];
        for (final url in take) {
          if (isChannelSection(url) || youtubeChannelRoot(url) != null) {
            if (!seen.contains(url)) seen.add(url);
            continue;
          }
          final kept = await _queue(container, url);
          if (kept && !seen.contains(url)) seen.add(url);
          if (kept) queued++;
        }
        next.add(set.copyWith(
          seen: seen.length > 500 ? seen.sublist(seen.length - 500) : seen,
          lastCheck: DateTime.now(),
        ));
      } catch (_) {
        next.add(set);
      }
    }
    await _save(next);
    return queued;
  }

  /// True when this URL should not be tried again (saved, skipped, or queued).
  static Future<bool> _queue(ProviderContainer container, String url) async {
    try {
      final media = await container.read(mediaRepositoryProvider).analyze(url);
      if (!media.canDownload) return true;
      final settings = container.read(settingsControllerProvider);
      final remembered = settings.qualityByPlatform[media.platform.id];
      MediaFormat? format;
      for (final item in media.formats) {
        if (remembered != null && item.quality.toLowerCase() == remembered.toLowerCase()) {
          format = item;
          break;
        }
      }
      format ??= _quality(media.formats, 'auto') ?? media.defaultFormat;
      if (format == null) return true;
      await container.read(downloadManagerProvider.notifier).enqueue(
            media: media,
            format: format,
            askExport: false,
          );
      return true;
    } on AppException catch (error) {
      return error.message.toLowerCase().contains('already saved');
    } catch (_) {
      return false;
    }
  }

  static MediaFormat? _quality(List<MediaFormat> formats, String quality) {
    for (final item in formats) {
      if (item.quality.toLowerCase() == quality) return item;
    }
    return null;
  }
}
