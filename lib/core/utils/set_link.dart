import 'dart:async';

import 'package:social_save/core/utils/platform_detector.dart';
import 'package:social_save/shared/models/playlist_entry.dart';
import 'package:social_save/shared/models/social_platform.dart';

const _youtubeTabs = {
  'videos',
  'shorts',
  'streams',
  'live',
  'playlists',
  'releases',
  'podcasts',
  'posts',
  'community',
  'about',
  'featured',
  'channels',
};

/// A public page that lists many posts: a YouTube playlist, a TikTok profile,
/// an Instagram highlight, or a Facebook album.
///
/// A single video, a login page, and a private story are not a set.
bool isPublicSet(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.host.isEmpty) return false;
  final platform = const PlatformDetector().detectUri(uri);
  final host = uri.host.toLowerCase();
  final path = uri.path;
  final segs = path.split('/').where((part) => part.isNotEmpty).toList();
  const blocked = {'login', 'accounts', 'challenge', 'checkpoint', 'recover', 'signup'};
  if (segs.any(blocked.contains)) return false;

  if (platform == SocialPlatform.youtube) {
    if (path == '/playlist' || path.endsWith('/playlist')) return true;
    final list = uri.queryParameters['list'];
    final video = uri.queryParameters['v'];
    if (list != null && list.isNotEmpty && (video == null || video.isEmpty) && !path.startsWith('/shorts/')) {
      return true;
    }
    // A public channel, including the Videos or Shorts tab.
    // /@name/shorts/id is one video and stays one video.
    if (segs.isNotEmpty && segs.first.startsWith('@') && segs.first.length > 1) {
      if (segs.length == 1) return true;
      if (segs.length == 2 && _youtubeTabs.contains(segs[1].toLowerCase())) return true;
    }
    if (segs.length >= 2 &&
        (segs[0] == 'channel' || segs[0] == 'c' || segs[0] == 'user') &&
        segs[1].isNotEmpty) {
      return true;
    }
    return false;
  }
  if (platform == SocialPlatform.tiktok) {
    // A profile, not one post. Short links (vm.tiktok.com) stay single videos.
    if (host.contains('vm.tiktok.com') || host.contains('vt.tiktok.com')) return false;
    return segs.length == 1 && segs.first.startsWith('@') && segs.first.length > 1;
  }
  if (platform == SocialPlatform.instagram) {
    return segs.length >= 3 && segs[0] == 'stories' && segs[1] == 'highlights' && segs[2].isNotEmpty;
  }
  if (platform == SocialPlatform.facebook) {
    final lower = path.toLowerCase();
    if (lower.contains('/media/set') || lower.contains('/albums/') || lower.contains('/album/')) {
      return true;
    }
    final set = uri.queryParameters['set'];
    return set != null && set.isNotEmpty;
  }
  return false;
}

/// A YouTube channel tab such as /@name/videos, not one video and not the channel root.
bool isChannelSection(String raw) {
  final uri = _youtubeUri(raw);
  if (uri == null) return false;
  final segs = _pathSegs(uri);
  if (segs.length == 2 && segs.first.startsWith('@') && segs.first.length > 1) {
    return _youtubeTabs.contains(segs[1].toLowerCase());
  }
  if (segs.length == 3 &&
      (segs[0] == 'channel' || segs[0] == 'c' || segs[0] == 'user') &&
      segs[1].isNotEmpty) {
    return _youtubeTabs.contains(segs[2].toLowerCase());
  }
  return false;
}

/// Channel root for a channel page or one of its tabs (Videos, Shorts, Live).
/// Null for a watch URL, a playlist, or anything that is not YouTube.
String? youtubeChannelBase(String raw) {
  final root = youtubeChannelRoot(raw);
  if (root != null) return root;
  final uri = _youtubeUri(raw);
  if (uri == null) return null;
  final segs = _pathSegs(uri);
  if (segs.length == 2 &&
      segs.first.startsWith('@') &&
      segs.first.length > 1 &&
      _youtubeTabs.contains(segs[1].toLowerCase())) {
    return '${uri.scheme}://${uri.host}/${segs.first}';
  }
  if (segs.length == 3 &&
      (segs[0] == 'channel' || segs[0] == 'c' || segs[0] == 'user') &&
      segs[1].isNotEmpty &&
      _youtubeTabs.contains(segs[2].toLowerCase())) {
    return '${uri.scheme}://${uri.host}/${segs[0]}/${segs[1]}';
  }
  return null;
}

/// `videos`, `shorts`, or `streams` when [raw] is that channel tab. Live counts as streams.
String? youtubeChannelTab(String raw) {
  final uri = _youtubeUri(raw);
  if (uri == null) return null;
  final segs = _pathSegs(uri);
  String? tab;
  if (segs.length == 2 && segs.first.startsWith('@') && segs.first.length > 1) {
    tab = segs[1].toLowerCase();
  } else if (segs.length == 3 &&
      (segs[0] == 'channel' || segs[0] == 'c' || segs[0] == 'user') &&
      segs[1].isNotEmpty) {
    tab = segs[2].toLowerCase();
  }
  if (tab == null || !_youtubeTabs.contains(tab)) return null;
  if (tab == 'live') return 'streams';
  return tab;
}

/// https://www.youtube.com/@name/videos or the same channel's Shorts tab.
String? youtubeChannelTabUrl(String raw, String tab) {
  final base = youtubeChannelBase(raw);
  if (base == null) return null;
  final name = tab.toLowerCase() == 'live' ? 'streams' : tab.toLowerCase();
  return '$base/$name';
}

/// https://www.youtube.com/@name or /channel/id, with no tab and no video id.
/// Null for a tab, a watch URL, or anything that is not YouTube.
String? youtubeChannelRoot(String raw) {
  final uri = _youtubeUri(raw);
  if (uri == null) return null;
  final segs = _pathSegs(uri);
  String? path;
  if (segs.length == 1 && segs.first.startsWith('@') && segs.first.length > 1) {
    path = '/${segs.first}';
  } else if (segs.length == 2 &&
      (segs[0] == 'channel' || segs[0] == 'c' || segs[0] == 'user') &&
      segs[1].isNotEmpty) {
    path = '/${segs[0]}/${segs[1]}';
  }
  if (path == null) return null;
  return '${uri.scheme}://${uri.host}$path';
}

/// When a channel page only lists Videos, Live, and Shorts tabs, open those
/// tabs once and keep the video links. A normal playlist is returned as it is.
/// Tabs are not opened again. At most [cap] videos are kept.
Future<List<PlaylistEntry>> expandChannelSections(
  List<PlaylistEntry> items,
  Future<List<PlaylistEntry>> Function(String url) load, {
  int cap = 40,
  Duration tabTimeout = const Duration(seconds: 25),
  String? onlyTab,
}) async {
  final wanted = onlyTab == null
      ? null
      : (onlyTab.toLowerCase() == 'live' ? 'streams' : onlyTab.toLowerCase());
  final targets = <String>[];
  final direct = <PlaylistEntry>[];
  for (final item in items) {
    final url = item.url.trim();
    if (isChannelSection(url)) {
      if (wanted != null && youtubeChannelTab(url) != wanted) continue;
      if (!targets.contains(url)) targets.add(url);
      continue;
    }
    final root = youtubeChannelRoot(url);
    if (root != null) {
      final tabs = wanted == null ? const ['videos', 'shorts', 'streams'] : [wanted];
      for (final tab in tabs) {
        final next = '$root/$tab';
        if (!targets.contains(next)) targets.add(next);
      }
      continue;
    }
    direct.add(item);
  }
  if (targets.isEmpty) return wanted == null ? items : direct;

  targets.sort((a, b) => _tabRank(a).compareTo(_tabRank(b)));
  final out = <PlaylistEntry>[];
  final seen = <String>{};
  void add(PlaylistEntry entry) {
    final url = entry.url.trim();
    if (url.isEmpty || seen.contains(url) || out.length >= cap) return;
    if (isChannelSection(url) || youtubeChannelRoot(url) != null) return;
    seen.add(url);
    out.add(entry);
  }

  for (final item in direct) {
    add(item);
  }
  for (final url in targets) {
    if (out.length >= cap) break;
    try {
      final nested = await load(url).timeout(tabTimeout);
      for (final child in nested) {
        add(child);
      }
    } catch (_) {}
  }
  return out;
}

Uri? _youtubeUri(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.host.isEmpty) return null;
  if (const PlatformDetector().detectUri(uri) != SocialPlatform.youtube) return null;
  return uri;
}

List<String> _pathSegs(Uri uri) => uri.path.split('/').where((part) => part.isNotEmpty).toList();

int _tabRank(String url) {
  final uri = Uri.tryParse(url);
  final segs = uri == null ? const <String>[] : _pathSegs(uri);
  final tab = segs.isEmpty ? '' : segs.last.toLowerCase();
  if (tab == 'videos') return 0;
  if (tab == 'shorts') return 1;
  if (tab == 'streams' || tab == 'live') return 2;
  return 3;
}
