import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/shared/widgets/page_layout.dart';

/// A direct chat. Links open the existing save preview.
class ChatThreadScreen extends StatefulWidget {
  const ChatThreadScreen({super.key, required this.threadId, required this.username});

  final String threadId;
  final String username;

  @override
  State<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends State<ChatThreadScreen> {
  final ChatApi _api = ChatApi();
  final TextEditingController _text = TextEditingController();
  final ScrollController _scroll = ScrollController();
  List<ChatMessage> _messages = const [];
  Timer? _poll;
  String _me = '';
  String? _error;
  bool _starting = true;
  bool _sending = false;
  bool _refreshing = false;
  int _after = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    _me = await ChatSession.username();
    if (!mounted) return;
    if (widget.threadId.isEmpty) {
      setState(() {
        _starting = false;
        _error = 'That chat was not found.';
      });
      return;
    }
    await _refresh();
    if (!mounted || widget.threadId.isEmpty) return;
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => unawaited(_refresh()));
  }

  Future<void> _refresh() async {
    if (_sending || _refreshing || widget.threadId.isEmpty) return;
    _refreshing = true;
    try {
      final items = await _api.messages(widget.threadId, _after);
      if (!mounted) return;
      final known = _messages.map((item) => item.id).toSet();
      final fresh = [for (final item in items) if (!known.contains(item.id)) item];
      if (fresh.isEmpty && !_starting) {
        if (_error != null) setState(() => _error = null);
        return;
      }
      var next = _after;
      for (final item in fresh) {
        if (item.id > next) next = item.id;
      }
      setState(() {
        _messages = [..._messages, ...fresh];
        _after = next;
        _error = null;
        _starting = false;
      });
      if (fresh.isNotEmpty) _jumpToEnd();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = chatErrorText(error);
        _starting = false;
      });
    } finally {
      _refreshing = false;
    }
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _sending || widget.threadId.isEmpty) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final message = await _api.send(widget.threadId, text);
      if (!mounted) return;
      _text.clear();
      setState(() {
        if (!_messages.any((item) => item.id == message.id)) {
          _messages = [..._messages, message];
        }
        if (message.id > _after) _after = message.id;
        _sending = false;
      });
      _jumpToEnd();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = chatErrorText(error);
      });
    }
  }

  void _openLink(String url) {
    context.push('/preview', extra: url);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = widget.username.trim().isEmpty ? 'Chat' : '@${widget.username.replaceFirst(RegExp(r'^@'), '')}';
    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: pageTitleStyle(context)),
      ),
      body: Column(
        children: [
          if (_error != null)
            Padding(
              padding: pagePadding(context, top: 8, bottom: 0),
              child: Text(_error!, style: TextStyle(color: scheme.error, height: 1.35)),
            ),
          Expanded(
            child: _starting
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            'No messages yet. Paste a public link, then tap it to save it.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: pagePadding(context, top: 12, bottom: 12),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final message = _messages[index];
                          return _Bubble(
                            message: message,
                            mine: message.name == _me && _me.isNotEmpty,
                            onLink: _openLink,
                          );
                        },
                      ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: pagePadding(context, top: 4, bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => unawaited(_send()),
                      decoration: const InputDecoration(
                        hintText: 'Write a message or paste a link',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Send',
                    onPressed: _sending ? null : () => unawaited(_send()),
                    icon: _sending
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine, required this.onLink});

  final ChatMessage message;
  final bool mine;
  final ValueChanged<String> onLink;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final time = TimeOfDay.fromDateTime(message.at.toLocal()).format(context);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 460),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${message.name} · $time',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            _LinkText(text: message.text, links: message.links, onLink: onLink),
          ],
        ),
      ),
    );
  }
}

class _LinkText extends StatelessWidget {
  const _LinkText({required this.text, required this.links, required this.onLink});

  final String text;
  final List<String> links;
  final ValueChanged<String> onLink;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pieces = _pieces(text, links);
    return Text.rich(
      TextSpan(
        style: TextStyle(fontSize: 15, height: 1.35, color: scheme.onSurface),
        children: [
          for (final piece in pieces)
            if (piece.url == null)
              TextSpan(text: piece.text)
            else
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: GestureDetector(
                  onTap: () => onLink(piece.url!),
                  child: Text(
                    piece.text,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.35,
                      color: scheme.primary,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

class _Piece {
  const _Piece(this.text, this.url);
  final String text;
  final String? url;
}

List<_Piece> _pieces(String text, List<String> links) {
  if (links.isEmpty || text.isEmpty) return [_Piece(text, null)];
  final pieces = <_Piece>[];
  var cursor = 0;
  for (final link in links) {
    final at = text.indexOf(link, cursor);
    if (at < 0) continue;
    if (at > cursor) pieces.add(_Piece(text.substring(cursor, at), null));
    pieces.add(_Piece(link, link));
    cursor = at + link.length;
  }
  if (cursor < text.length) pieces.add(_Piece(text.substring(cursor), null));
  if (pieces.isEmpty) return [_Piece(text, null)];
  return pieces;
}
