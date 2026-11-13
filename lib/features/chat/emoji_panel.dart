import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/features/chat/emoji_catalog.dart';

/// The emoji sheet on a message or status field.
///
/// Frequent and Favorites stay at the front. A long press keeps or drops a favorite.
class EmojiPanel extends StatefulWidget {
  const EmojiPanel({super.key, required this.onPick});

  final ValueChanged<String> onPick;

  @override
  State<EmojiPanel> createState() => _EmojiPanelState();
}

class _EmojiPanelState extends State<EmojiPanel> {
  static const _recentKey = 'chat.emoji.recent.v1';
  static const _favKey = 'chat.emoji.fav.v1';

  final TextEditingController _search = TextEditingController();
  List<String> _recent = const [];
  List<String> _favorites = const [];
  String _group = 'Frequent';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _recent = prefs.getStringList(_recentKey) ?? const [];
      _favorites = prefs.getStringList(_favKey) ?? const [];
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _pick(String emoji) async {
    widget.onPick(emoji);
    final next = rememberEmoji(_recent, emoji);
    setState(() => _recent = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentKey, next);
  }

  Future<void> _favorite(String emoji) async {
    final next = toggleFavorite(_favorites, emoji);
    setState(() => _favorites = next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_favKey, next);
  }

  List<String> get _shown {
    final query = _search.text.trim();
    if (query.isNotEmpty) {
      return [for (final item in searchEmojis(query)) item.char];
    }
    if (_group == 'Frequent') return _recent;
    if (_group == 'Favorites') return _favorites;
    return [for (final item in emojisIn(_group)) item.char];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chips = ['Frequent', 'Favorites', ...emojiGroupOrder];
    final shown = _shown;
    return Material(
      color: scheme.surface,
      child: SizedBox(
        height: 320,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: 'Search emoji',
                  isDense: true,
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final name in chips)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text(name),
                        selected: _search.text.trim().isEmpty && _group == name,
                        onSelected: (_) => setState(() {
                          _group = name;
                          _search.clear();
                        }),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: shown.isEmpty
                  ? Center(
                      child: Text(
                        _search.text.trim().isNotEmpty
                            ? 'No emoji matches that.'
                            : _group == 'Favorites'
                            ? 'Hold an emoji to keep it here.'
                            : 'No emoji yet.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 8,
                        mainAxisSpacing: 4,
                        crossAxisSpacing: 4,
                      ),
                      itemCount: shown.length,
                      itemBuilder: (context, index) {
                        final emoji = shown[index];
                        return InkWell(
                          onTap: () => _pick(emoji),
                          onLongPress: () => _favorite(emoji),
                          child: Center(
                            child: Text(emoji, style: const TextStyle(fontSize: 26)),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
