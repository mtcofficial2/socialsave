import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A public link kept in the library without a downloaded file.
class WatchLaterItem {
  const WatchLaterItem({
    required this.url,
    required this.title,
    this.platform = '',
    this.author,
  });

  final String url;
  final String title;
  final String platform;
  final String? author;

  Map<String, String?> toJson() => {
        'url': url,
        'title': title,
        'platform': platform,
        'author': author,
      };

  factory WatchLaterItem.fromJson(Map<dynamic, dynamic> json) {
    final author = '${json['author'] ?? ''}'.trim();
    final title = '${json['title'] ?? ''}'.trim();
    return WatchLaterItem(
      url: '${json['url'] ?? ''}'.trim(),
      title: title.isEmpty ? 'Video' : title,
      platform: '${json['platform'] ?? ''}'.trim(),
      author: author.isEmpty ? null : author,
    );
  }
}

class LibraryCatalog {
  const LibraryCatalog({
    this.favorites = const {},
    this.collections = const {},
    this.notes = const {},
    this.later = const [],
  });

  final Set<String> favorites;
  final Map<String, List<String>> collections;
  final Map<String, String> notes;
  final List<WatchLaterItem> later;

  bool isFavorite(String key) => favorites.contains(key);

  bool inCollection(String name, String key) {
    return collections[name]?.contains(key) ?? false;
  }

  List<String> get collectionNames {
    final names = collections.keys.toList()..sort();
    return names;
  }

  String encode() {
    return jsonEncode({
      'favorites': favorites.toList(),
      'collections': collections,
      'notes': notes,
      'later': [for (final item in later) item.toJson()],
    });
  }

  factory LibraryCatalog.decode(String raw) {
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return const LibraryCatalog();
      final favorites = <String>{};
      final fav = data['favorites'];
      if (fav is List) {
        favorites.addAll(fav.map((item) => '$item'));
      }
      final collections = <String, List<String>>{};
      final groups = data['collections'];
      if (groups is Map) {
        for (final entry in groups.entries) {
          final items = entry.value;
          if (items is List) {
            collections['${entry.key}'] = items.map((item) => '$item').toList();
          }
        }
      }
      final notes = <String, String>{};
      final rawNotes = data['notes'];
      if (rawNotes is Map) {
        for (final entry in rawNotes.entries) {
          final text = '${entry.value}'.trim();
          if (text.isNotEmpty) notes['${entry.key}'] = text;
        }
      }
      final later = <WatchLaterItem>[];
      final rawLater = data['later'];
      if (rawLater is List) {
        for (final item in rawLater) {
          if (item is! Map) continue;
          final row = WatchLaterItem.fromJson(item);
          if (row.url.isNotEmpty) later.add(row);
        }
      }
      return LibraryCatalog(favorites: favorites, collections: collections, notes: notes, later: later);
    } catch (_) {
      return const LibraryCatalog();
    }
  }
}

final libraryCatalogProvider =
    NotifierProvider<LibraryCatalogController, LibraryCatalog>(LibraryCatalogController.new);

class LibraryCatalogController extends Notifier<LibraryCatalog> {
  static const _pref = 'socialsave_library_catalog';
  Future<void> _ready = Future<void>.value();

  @override
  LibraryCatalog build() {
    final done = Completer<void>();
    _ready = done.future;
    Future<void>(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_pref);
        if (raw != null && raw.isNotEmpty) {
          state = LibraryCatalog.decode(raw);
        }
      } finally {
        if (!done.isCompleted) done.complete();
      }
    });
    return const LibraryCatalog();
  }

  Future<void> toggleFavorite(String key) async {
    await _ready;
    final next = Set<String>.from(state.favorites);
    if (!next.add(key)) next.remove(key);
    state = LibraryCatalog(favorites: next, collections: state.collections, notes: state.notes, later: state.later);
    await _save();
  }

  Future<void> setNote(String key, String note) async {
    await _ready;
    final notes = Map<String, String>.from(state.notes);
    final trimmed = note.trim();
    if (trimmed.isEmpty) {
      notes.remove(key);
    } else {
      notes[key] = trimmed;
    }
    state = LibraryCatalog(favorites: state.favorites, collections: state.collections, notes: notes, later: state.later);
    await _save();
  }

  Future<void> addLater(WatchLaterItem item) async {
    await _ready;
    final url = item.url.trim();
    if (url.isEmpty) return;
    final next = <WatchLaterItem>[
      item,
      for (final old in state.later)
        if (old.url != url) old,
    ];
    state = LibraryCatalog(
      favorites: state.favorites,
      collections: state.collections,
      notes: state.notes,
      later: next,
    );
    await _save();
  }

  Future<void> removeLater(String url) async {
    await _ready;
    final next = [for (final old in state.later) if (old.url != url) old];
    if (next.length == state.later.length) return;
    state = LibraryCatalog(
      favorites: state.favorites,
      collections: state.collections,
      notes: state.notes,
      later: next,
    );
    await _save();
  }

  Future<void> createCollection(String name) async {
    await _ready;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final collections = Map<String, List<String>>.from(state.collections);
    collections.putIfAbsent(trimmed, () => const []);
    state = LibraryCatalog(favorites: state.favorites, collections: collections, notes: state.notes, later: state.later);
    await _save();
  }

  Future<void> addToCollection(String name, String key) async {
    await _ready;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final collections = <String, List<String>>{};
    for (final entry in state.collections.entries) {
      collections[entry.key] = List<String>.from(entry.value);
    }
    final items = collections.putIfAbsent(trimmed, () => <String>[]);
    if (!items.contains(key)) items.add(key);
    state = LibraryCatalog(favorites: state.favorites, collections: collections, notes: state.notes, later: state.later);
    await _save();
  }

  /// Removes [key] from every collection, then puts it in [name].
  Future<void> moveToCollection(String name, String key) async {
    await _ready;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final collections = <String, List<String>>{};
    for (final entry in state.collections.entries) {
      collections[entry.key] = entry.value.where((item) => item != key).toList();
    }
    final items = collections.putIfAbsent(trimmed, () => <String>[]);
    if (!items.contains(key)) items.add(key);
    state = LibraryCatalog(favorites: state.favorites, collections: collections, notes: state.notes, later: state.later);
    await _save();
  }

  Future<void> replace(LibraryCatalog next) async {
    await _ready;
    state = next;
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pref, state.encode());
  }
}
