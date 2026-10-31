import 'dart:async';

import 'package:flutter/material.dart';
import 'package:social_save/features/chat/chat_link_stub.dart'
    if (dart.library.io) 'package:social_save/features/chat/chat_link_io.dart';

export 'package:social_save/features/chat/chat_link_rules.dart';

class ChatLinkPreview {
  const ChatLinkPreview({required this.title, required this.image});

  final String title;
  final String image;
}

class ChatLinkCards {
  static final Map<String, ChatLinkPreview?> _cache = {};
  static final Map<String, Future<ChatLinkPreview?>> _loading = {};

  static Future<ChatLinkPreview?> fetch(String url) {
    final pending = _loading[url];
    if (pending != null) return pending;
    if (_cache.containsKey(url)) {
      final done = Future<ChatLinkPreview?>.value(_cache[url]);
      _loading[url] = done;
      return done;
    }
    final future = _load(url);
    _loading[url] = future;
    return future;
  }

  static Future<ChatLinkPreview?> _load(String url) async {
    try {
      final page = await fetchChatPage(url);
      final preview = page == null ? null : ChatLinkPreview(title: page.title, image: page.image);
      _cache[url] = preview;
      return preview;
    } catch (_) {
      final pending = _loading.remove(url);
      if (pending != null) unawaited(pending);
      return null;
    }
  }
}

/// A small card for the first public link. Tap still opens Save.
class ChatLinkCard extends StatelessWidget {
  const ChatLinkCard({super.key, required this.url, required this.onOpen});

  final String url;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ChatLinkPreview?>(
      future: ChatLinkCards.fetch(url),
      builder: (context, snapshot) {
        final preview = snapshot.data;
        if (preview == null) return const SizedBox.shrink();
        final dark = Theme.of(context).brightness == Brightness.dark;
        final title = preview.title.trim();
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Material(
            color: dark ? const Color(0xFF0B141A) : const Color(0xFFF7F4EF),
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => onOpen(url),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (preview.image.isNotEmpty)
                    Image.network(
                      preview.image,
                      height: 132,
                      fit: BoxFit.cover,
                      cacheWidth: 480,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  if (title.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: dark ? const Color(0xFFE9EDEF) : const Color(0xFF111B21),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
