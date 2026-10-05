import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LibraryCatalog {
  const LibraryCatalog({
    this.favorites = const {},
    this.collections = const {},
    this.notes = const {},
  });

  final Set<String> favorites;
  final Map<String, List<String>> collections;
  final Map<String, String> notes;

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
      return LibraryCatalog(favorites: favorites, collections: collections, notes: notes);
    } catch (_) {
      return const LibraryCatalog();
    }
  }
}

final libraryCatalogProvider =
    NotifierProvider<LibraryCatalogController, LibraryCatalog>(LibraryCatalogController.new);

class LibraryCatalogController extends Notifier<LibraryCatalog> {
  static const _pref = 'socialsave_library_catalog';

  @override
  LibraryCatalog build() {
    Future<void>(() async {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pref);
      if (raw == null || raw.isEmpty) return;
      state = LibraryCatalog.decode(raw);
    });
    return const LibraryCatalog();
  }

  Future<void> toggleFavorite(String key) async {
    final next = Set<String>.from(state.favorites);
    if (!next.add(key)) next.remove(key);
    state = LibraryCatalog(favorites: next, collections: state.collections, notes: state.notes);
    await _save();
  }

  Future<void> setNote(String key, String note) async {
    final notes = Map<String, String>.from(state.notes);
    final trimmed = note.trim();
    if (trimmed.isEmpty) {
      notes.remove(key);
    } else {
      notes[key] = trimmed;
    }
    state = LibraryCatalog(favorites: state.favorites, collections: state.collections, notes: notes);
    await _save();
  }

  Future<void> createCollection(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final collections = Map<String, List<String>>.from(state.collections);
    collections.putIfAbsent(trimmed, () => const []);
    state = LibraryCatalog(favorites: state.favorites, collections: collections, notes: state.notes);
    await _save();
  }

  Future<void> addToCollection(String name, String key) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final collections = <String, List<String>>{};
    for (final entry in state.collections.entries) {
      collections[entry.key] = List<String>.from(entry.value);
    }
    final items = collections.putIfAbsent(trimmed, () => <String>[]);
    if (!items.contains(key)) items.add(key);
    state = LibraryCatalog(favorites: state.favorites, collections: collections, notes: state.notes);
    await _save();
  }

  Future<void> replace(LibraryCatalog next) async {
    state = next;
    await _save();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pref, state.encode());
  }
}
