import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const chatDraftKey = 'chat.drafts.v1';

/// Half-written messages stay on this device, one per conversation.
class ChatDrafts {
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);
  static final Map<String, String> _items = {};
  static bool _loaded = false;

  static String peek(String threadId) => _items[threadId] ?? '';

  static Future<void> ensure() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(chatDraftKey);
    _items.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final key = entry.key;
            final value = entry.value;
            if (key is String && value is String && value.trim().isNotEmpty) {
              _items[key] = value;
            }
          }
        }
      } catch (_) {}
    }
    _loaded = true;
    revision.value++;
  }

  static Future<String> read(String threadId) async {
    await ensure();
    return peek(threadId);
  }

  static Future<void> write(String threadId, String text) async {
    if (threadId.isEmpty) return;
    await ensure();
    final next = text.trim().isEmpty ? '' : text;
    final current = _items[threadId] ?? '';
    if (current == next) return;
    if (next.isEmpty) {
      _items.remove(threadId);
    } else {
      _items[threadId] = next;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(chatDraftKey, jsonEncode(_items));
    revision.value++;
  }
}
