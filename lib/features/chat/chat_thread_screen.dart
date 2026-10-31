import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/features/chat/chat_profile.dart';

/// A direct chat. On a phone this is its own page. On a wide window it sits
/// beside the chat list.
class ChatThreadScreen extends StatelessWidget {
  const ChatThreadScreen({super.key, required this.threadId, required this.username});

  final String threadId;
  final String username;

  @override
  Widget build(BuildContext context) {
    return ChatThreadView(threadId: threadId, username: username);
  }
}

class ChatThreadView extends StatefulWidget {
  const ChatThreadView({
    super.key,
    required this.threadId,
    required this.username,
    this.embedded = false,
    this.onRead,
  });

  final String threadId;
  final String username;
  final bool embedded;
  final void Function(String threadId, int lastId)? onRead;

  @override
  State<ChatThreadView> createState() => _ChatThreadViewState();
}

class _ChatThreadViewState extends State<ChatThreadView> {
  final ChatApi _api = ChatApi();
  final TextEditingController _text = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();
  List<ChatMessage> _messages = const [];
  Timer? _poll;
  String _me = '';
  String? _error;
  bool _starting = true;
  bool _sending = false;
  bool _refreshing = false;
  bool _stickToEnd = true;
  int _below = 0;
  int _after = 0;
  int _peerDelivered = 0;
  int _peerRead = 0;
  int _seenAtOpen = 0;
  int _bannerAfter = -1;

  bool get _enterSends {
    switch (Theme.of(context).platform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
        return true;
    }
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    unawaited(_open());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _scroll.removeListener(_onScroll);
    _text.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final distance = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    final stick = distance < 96;
    if (stick == _stickToEnd) return;
    setState(() {
      _stickToEnd = stick;
      if (stick) _below = 0;
    });
  }

  Future<void> _open() async {
    _me = await ChatSession.username();
    final seen = await ChatReads.load();
    _seenAtOpen = seen[widget.threadId] ?? 0;
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
      final sync = await _api.messages(widget.threadId, _after);
      if (!mounted) return;
      final known = _messages.map((item) => item.id).toSet();
      final fresh = [for (final item in sync.messages) if (!known.contains(item.id)) item];
      _peerDelivered = sync.peerDelivered;
      _peerRead = sync.peerRead;
      if (fresh.isEmpty && !_starting) {
        setState(() => _error = null);
        unawaited(_noteRead());
        return;
      }
      var next = _after;
      for (final item in fresh) {
        if (item.id > next) next = item.id;
      }
      final wasStarting = _starting;
      final stick = _stickToEnd || wasStarting;
      if (wasStarting) {
        final hasUnread = fresh.any((item) => item.name != _me && item.id > _seenAtOpen);
        _bannerAfter = hasUnread ? _seenAtOpen : -1;
      }
      setState(() {
        _messages = [..._messages, ...fresh];
        _after = next;
        _error = null;
        _starting = false;
        if (!stick) _below += fresh.where((item) => item.name != _me).length;
      });
      if (stick) _jump(animate: !wasStarting && fresh.isNotEmpty);
      unawaited(_noteRead());
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

  Future<void> _noteRead() async {
    if (_messages.isEmpty) return;
    var last = 0;
    for (final message in _messages) {
      if (message.id > last) last = message.id;
    }
    await ChatReads.mark(widget.threadId, last);
    widget.onRead?.call(widget.threadId, last);
    try {
      await _api.markRead(widget.threadId, last);
    } catch (_) {
      // The next poll tries again. Local unread still clears.
    }
  }

  void _jump({required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (!animate) {
        _scroll.jumpTo(target);
        return;
      }
      _scroll.animateTo(target, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
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
        _stickToEnd = true;
        _below = 0;
      });
      _jump(animate: true);
      unawaited(_noteRead());
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

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_enterSends || event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    unawaited(_send());
    return KeyEventResult.handled;
  }

  Future<void> _menu(ChatMessage message, LongPressStartDetails details) async {
    final box = Overlay.of(context).context.findRenderObject();
    if (box is! RenderBox) return;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(details.globalPosition.dx, details.globalPosition.dy, 0, 0),
        Offset.zero & box.size,
      ),
      items: [
        const PopupMenuItem(value: 'copy', child: Text('Copy')),
        if (message.links.isNotEmpty) const PopupMenuItem(value: 'save', child: Text('Save link')),
      ],
    );
    if (!mounted || selected == null) return;
    if (selected == 'copy') {
      await Clipboard.setData(ClipboardData(text: message.text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Message copied')));
      return;
    }
    _openLink(message.links.first);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = widget.username.replaceFirst(RegExp(r'^@'), '').trim();
    final title = name.isEmpty ? 'Chat' : name;
    final canvas = scheme.brightness == Brightness.dark ? const Color(0xFF0B141A) : const Color(0xFFEFE7DE);
    final body = Column(
      children: [
        AppBar(
          automaticallyImplyLeading: !widget.embedded,
          titleSpacing: widget.embedded ? 16 : 0,
          title: InkWell(
            onTap: () => unawaited(showChatProfile(context, username: title)),
            child: Row(
              children: [
                ChatAvatar(name: title, size: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(
                        'View profile',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_error != null)
          Material(
            color: scheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(_error!, style: TextStyle(color: scheme.onErrorContainer, height: 1.35)),
            ),
          ),
        Expanded(
          child: ColoredBox(
            color: canvas,
            child: _starting
                ? const Center(child: CircularProgressIndicator())
                : Stack(
                    children: [
                      _messages.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(32),
                                child: Text(
                                  'No messages yet. Say hello, or paste a public link. Tap a link to save it.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
                                ),
                              ),
                            )
                          : Builder(
                              builder: (context) {
                                final rows = _rows();
                                return ListView.builder(
                              controller: _scroll,
                              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                              itemCount: rows.length,
                              itemBuilder: (context, index) {
                                final row = rows[index];
                                if (row.banner != null) return _DayChip(label: row.banner!);
                                if (row.day != null) return _DayChip(label: row.day!);
                                final message = row.message!;
                                final mine = message.name == _me && _me.isNotEmpty;
                                return _Bubble(
                                  message: message,
                                  mine: mine,
                                  tick: chatTick(
                                    mine: mine,
                                    id: message.id,
                                    peerDelivered: _peerDelivered,
                                    peerRead: _peerRead,
                                    status: message.status,
                                  ),
                                  onLink: _openLink,
                                  onLongPress: (details) => unawaited(_menu(message, details)),
                                );
                              },
                            );
                              },
                            ),
                      if (_below > 0)
                        Positioned(
                          right: 12,
                          bottom: 12,
                          child: FloatingActionButton.small(
                            heroTag: 'chat-down-${widget.threadId}',
                            tooltip: 'New messages',
                            onPressed: () {
                              setState(() {
                                _stickToEnd = true;
                                _below = 0;
                              });
                              _jump(animate: true);
                            },
                            child: const Icon(Icons.keyboard_arrow_down_rounded),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        Material(
          color: scheme.surface,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _text,
                builder: (context, value, _) {
                  final canSend = value.text.trim().isNotEmpty && !_sending;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Focus(
                          onKeyEvent: _onKey,
                          child: TextField(
                            controller: _text,
                            focusNode: _focus,
                            minLines: 1,
                            maxLines: 5,
                            textInputAction: _enterSends ? TextInputAction.newline : TextInputAction.send,
                            onSubmitted: _enterSends ? null : (_) => unawaited(_send()),
                            decoration: InputDecoration(
                              hintText: 'Message',
                              filled: true,
                              fillColor: scheme.surfaceContainerHighest,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (canSend) ...[
                        const SizedBox(width: 6),
                        IconButton.filled(
                          tooltip: 'Send',
                          onPressed: () => unawaited(_send()),
                          icon: const Icon(Icons.send_rounded),
                        ),
                      ] else if (_sending)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(body: body);
  }

  List<_Row> _rows() {
    final rows = <_Row>[];
    DateTime? previous;
    final now = DateTime.now();
    var markedNew = false;
    var newCount = 0;
    for (final message in _messages) {
      if (message.name != _me && message.id > _seenAtOpen) newCount++;
    }
    for (final message in _messages) {
      final local = message.at.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      if (previous == null || day != previous) {
        rows.add(_Row.day(chatDayLabel(message.at, now)));
        previous = day;
      }
      final isNew = _bannerAfter >= 0 && message.name != _me && message.id > _bannerAfter;
      if (isNew && !markedNew) {
        markedNew = true;
        final label = newCount == 1 ? '1 unread message' : '$newCount unread messages';
        rows.add(_Row.banner(label));
      }
      rows.add(_Row.message(message));
    }
    return rows;
  }
}

class _Row {
  const _Row.day(this.day) : message = null, banner = null;
  const _Row.banner(this.banner) : message = null, day = null;
  const _Row.message(this.message) : day = null, banner = null;
  final String? day;
  final String? banner;
  final ChatMessage? message;
}

class ChatAvatar extends StatelessWidget {
  const ChatAvatar({super.key, required this.name, this.size = 48});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: chatAvatarColor(name),
      child: Text(
        chatInitial(name),
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: size * 0.38),
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant)),
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.mine,
    required this.tick,
    required this.onLink,
    required this.onLongPress,
  });

  final ChatMessage message;
  final bool mine;
  final String tick;
  final ValueChanged<String> onLink;
  final ValueChanged<LongPressStartDetails> onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final bg = mine
        ? (dark ? const Color(0xFF005C4B) : const Color(0xFFD9FDD3))
        : (dark ? const Color(0xFF202C33) : Colors.white);
    final fg = dark ? const Color(0xFFE9EDEF) : const Color(0xFF111B21);
    final link = dark ? const Color(0xFF53BDEB) : const Color(0xFF027EB5);
    final time = TimeOfDay.fromDateTime(message.at.toLocal()).format(context);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPressStart: onLongPress,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 460),
          margin: const EdgeInsets.only(bottom: 3, top: 1),
          padding: const EdgeInsets.fromLTRB(10, 6, 8, 4),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(12),
              topRight: const Radius.circular(12),
              bottomLeft: Radius.circular(mine ? 12 : 2),
              bottomRight: Radius.circular(mine ? 2 : 12),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _LinkText(text: message.text, links: message.links, color: fg, linkColor: link, onLink: onLink),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(time, style: TextStyle(fontSize: 11, color: fg.withValues(alpha: 0.62))),
                  if (tick.isNotEmpty) ...[
                    const SizedBox(width: 3),
                    Icon(
                      tick == 'sent' ? Icons.done_rounded : Icons.done_all_rounded,
                      size: 15,
                      color: tick == 'read' ? const Color(0xFF53BDEB) : fg.withValues(alpha: 0.62),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LinkText extends StatelessWidget {
  const _LinkText({
    required this.text,
    required this.links,
    required this.color,
    required this.linkColor,
    required this.onLink,
  });

  final String text;
  final List<String> links;
  final Color color;
  final Color linkColor;
  final ValueChanged<String> onLink;

  @override
  Widget build(BuildContext context) {
    final pieces = _pieces(text, links);
    return Align(
      alignment: Alignment.centerLeft,
      child: Text.rich(
        TextSpan(
          style: TextStyle(fontSize: 15.5, height: 1.3, color: color),
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
                        fontSize: 15.5,
                        height: 1.3,
                        color: linkColor,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
          ],
        ),
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
