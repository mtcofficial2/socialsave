import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/utils/platform_detector.dart';
import 'package:social_save/core/utils/set_link.dart';

/// A YouTube channel or TikTok profile kept on Home.
class FavoriteCreator {
  const FavoriteCreator({
    required this.url,
    required this.name,
    required this.platform,
    this.avatarUrl,
    this.checked = false,
  });

  final String url;
  final String name;
  final String platform;
  final String? avatarUrl;

  /// True after one attempt to load the name and portrait.
  final bool checked;

  FavoriteCreator copyWith({
    String? name,
    String? avatarUrl,
    bool? checked,
  }) {
    return FavoriteCreator(
      url: url,
      name: name ?? this.name,
      platform: platform,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      checked: checked ?? this.checked,
    );
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'name': name,
        'platform': platform,
        'avatar': avatarUrl,
        'checked': checked,
      };

  factory FavoriteCreator.fromJson(Map<dynamic, dynamic> json) {
    final url = '${json['url'] ?? ''}'.trim();
    final stored = creatorDisplayName('${json['name'] ?? ''}');
    final avatar = '${json['avatar'] ?? ''}'.trim();
    return FavoriteCreator(
      url: url,
      name: stored ?? creatorHandleName(url),
      platform: '${json['platform'] ?? ''}'.trim(),
      avatarUrl: isCreatorPortrait(avatar) ? avatar : null,
      checked: json['checked'] == true,
    );
  }

  static List<FavoriteCreator> decodeList(String raw) {
    try {
      final data = jsonDecode(raw);
      if (data is! List) return const [];
      return [
        for (final item in data)
          if (item is Map) FavoriteCreator.fromJson(item),
      ].where((item) => item.url.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }
}

final favoriteCreatorsProvider =
    NotifierProvider<FavoriteCreatorsController, List<FavoriteCreator>>(FavoriteCreatorsController.new);

class FavoriteCreatorsController extends Notifier<List<FavoriteCreator>> {
  static const prefKey = 'socialsave_favorite_creators';
  Future<void> _ready = Future<void>.value();

  @override
  List<FavoriteCreator> build() {
    final done = Completer<void>();
    _ready = done.future;
    Future<void>(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(prefKey);
        if (raw != null && raw.isNotEmpty) {
          state = FavoriteCreator.decodeList(raw);
        }
      } finally {
        if (!done.isCompleted) done.complete();
      }
      unawaited(_fillMissing());
    });
    return const [];
  }

  bool contains(String url) {
    final home = creatorHome(url) ?? url.trim();
    return state.any((item) => item.url == home);
  }

  Future<void> add(String url, {String? name, String? avatarUrl}) async {
    await _ready;
    final home = creatorHome(url);
    if (home == null) return;
    final platform = const PlatformDetector().detect(home).id;
    final label = creatorDisplayName(name) ?? creatorHandleName(home);
    final portrait = isCreatorPortrait(avatarUrl) ? avatarUrl!.trim() : null;
    state = [
      FavoriteCreator(
        url: home,
        name: label,
        platform: platform,
        avatarUrl: portrait,
        checked: portrait != null,
      ),
      for (final item in state)
        if (item.url != home) item,
    ].take(60).toList();
    await _save();
    if (portrait == null) unawaited(_fill(home));
  }

  /// Keeps a saved creator's name and portrait when a later page load learns them.
  Future<void> remember(String url, {String? name, String? avatarUrl}) async {
    await _ready;
    final home = creatorHome(url);
    if (home == null) return;
    final index = state.indexWhere((item) => item.url == home);
    if (index < 0) return;
    final current = state[index];
    final label = creatorDisplayName(name);
    final portrait = isCreatorPortrait(avatarUrl) ? avatarUrl!.trim() : null;
    if (label == null && portrait == null) return;
    final next = [...state];
    next[index] = current.copyWith(
      name: label ?? current.name,
      avatarUrl: portrait ?? current.avatarUrl,
      checked: portrait != null || current.checked,
    );
    state = next;
    await _save();
  }

  Future<void> remove(String url) async {
    await _ready;
    final home = creatorHome(url) ?? url.trim();
    state = [for (final item in state) if (item.url != home) item];
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefKey, jsonEncode([for (final item in state) item.toJson()]));
  }

  Future<void> _fillMissing() async {
    await _ready;
    final pending = state.where((item) => !item.checked).take(4).map((item) => item.url).toList();
    for (final url in pending) {
      await _fill(url);
    }
  }

  Future<void> _fill(String url) async {
    String? name;
    String? avatar;
    try {
      final page = await ref.read(mediaRepositoryProvider).playlistPage(url).timeout(const Duration(seconds: 25));
      name = creatorDisplayName(page.name);
      if (isCreatorPortrait(page.avatarUrl)) avatar = page.avatarUrl!.trim();
    } catch (_) {}
    if (avatar == null) {
      try {
        final media = await ref.read(mediaRepositoryProvider).analyze(url).timeout(const Duration(seconds: 20));
        name ??= creatorDisplayName(media.author) ?? creatorDisplayName(media.title);
        if (isCreatorPortrait(media.thumbnailUrl)) avatar = media.thumbnailUrl!.trim();
      } catch (_) {}
    }
    await _ready;
    final index = state.indexWhere((item) => item.url == url);
    if (index < 0) return;
    final current = state[index];
    final next = [...state];
    next[index] = current.copyWith(
      name: name ?? current.name,
      avatarUrl: avatar ?? current.avatarUrl,
      checked: true,
    );
    state = next;
    await _save();
  }
}
