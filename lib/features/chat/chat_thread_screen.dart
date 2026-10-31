import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/features/chat/chat_profile.dart';
import 'package:social_save/features/chat/chat_voice.dart';

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

class _ChatThreadViewState extends State<ChatThreadView> with WidgetsBindingObserver {
  final ChatApi _api = ChatApi();
  final ChatRecorder _recorder = ChatRecorder();
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
  bool _recording = false;
  bool _finishingVoice = false;
  int _below = 0;
  int _after = 0;
  int _peerDelivered = 0;
  int _peerRead = 0;
  int _peerPhoto = 0;
  int _seenAtOpen = 0;
  int _bannerAfter = -1;
  int _readSent = 0;
  DateTime? _peerSeen;
  bool _peerOnline = false;

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
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    _recorder.onTick = () {
      if (!mounted) return;
      setState(() {});
      if (_recorder.shownMs >= 60000) unawaited(_finishVoice(send: true));
    };
    unawaited(_open());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    unawaited(_recorder.dispose());
    _scroll.removeListener(_onScroll);
    _text.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPoll();
      unawaited(_refresh());
    } else {
      _poll?.cancel();
      _poll = null;
    }
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
    _startPoll();
  }

  void _startPoll() {
    _poll?.cancel();
    if (widget.threadId.isEmpty) return;
    _poll = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;
      unawaited(_refresh());
    });
  }

  Future<void> _refresh() async {
    if (_sending || _refreshing || widget.threadId.isEmpty) return;
    _refreshing = true;
    try {
      final sync = await _api.messages(widget.threadId, _after);
      if (!mounted) return;
      final known = _messages.map((item) => item.id).toSet();
      final fresh = [for (final item in sync.messages) if (!known.contains(item.id)) item];
      final presenceChanged = sync.peerDelivered != _peerDelivered ||
          sync.peerRead != _peerRead ||
          sync.peerOnline != _peerOnline ||
          sync.peerPhotoRev != _peerPhoto ||
          sync.peerLastSeen != _peerSeen;
      _peerDelivered = sync.peerDelivered;
      _peerRead = sync.peerRead;
      _peerOnline = sync.peerOnline;
      _peerSeen = sync.peerLastSeen;
      _peerPhoto = sync.peerPhotoRev;
      if (fresh.isEmpty && !_starting) {
        if (presenceChanged || _error != null) setState(() => _error = null);
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
    if (last <= _readSent) return;
    await ChatReads.mark(widget.threadId, last);
    widget.onRead?.call(widget.threadId, last);
    try {
      await _api.markRead(widget.threadId, last);
      _readSent = last;
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
      _accept(message);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = chatErrorText(error);
      });
    }
  }

  void _accept(ChatMessage message) {
    setState(() {
      if (!_messages.any((item) => item.id == message.id)) {
        _messages = [..._messages, message];
      }
      if (message.id > _after) _after = message.id;
      _sending = false;
      _stickToEnd = true;
      _below = 0;
      _error = null;
    });
    _jump(animate: true);
    unawaited(_noteRead());
  }

  Future<void> _startVoice() async {
    if (_sending || _recording || widget.threadId.isEmpty || Plat.isWeb) return;
    final problem = await _recorder.begin();
    if (!mounted) return;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _recording = true;
      _error = null;
    });
  }

  Future<void> _finishVoice({required bool send}) async {
    if (_finishingVoice) return;
    _finishingVoice = true;
    try {
      final taken = await _recorder.stop(send: send);
      if (!mounted) return;
      setState(() => _recording = false);
      if (!send || taken == null) return;
      if (taken.ms < 500) {
        setState(() => _error = 'That voice note was too short.');
        return;
      }
      final file = File(taken.path);
      final bytes = await file.readAsBytes();
      unawaited(file.delete());
      if (!mounted) return;
      if (bytes.isEmpty) {
        setState(() => _error = 'That voice note could not be sent.');
        return;
      }
      setState(() => _sending = true);
      final ms = taken.ms > 60000 ? 60000 : taken.ms;
      final message = await _api.sendVoice(widget.threadId, bytes, ms);
      if (!mounted) return;
      _accept(message);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _recording = false;
        _error = chatErrorText(error);
      });
    } finally {
      _finishingVoice = false;
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
    final presence = chatPresenceLabel(
      _peerSeen,
      _peerOnline,
      DateTime.now(),
      _peerSeen == null ? '' : TimeOfDay.fromDateTime(_peerSeen!.toLocal()).format(context),
    );
    final body = Column(
      children: [
        AppBar(
          automaticallyImplyLeading: !widget.embedded,
          titleSpacing: widget.embedded ? 16 : 0,
          title: InkWell(
            onTap: () => unawaited(
              showChatProfile(
                context,
                username: title,
                photoRev: _peerPhoto,
                lastSeen: _peerSeen,
                online: _peerOnline,
              ),
            ),
            child: Row(
              children: [
                ChatFace(name: title, size: 36, photoRev: _peerPhoto, online: _peerOnline),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      if (presence.isNotEmpty)
                        Text(
                          presence,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: _peerOnline ? const Color(0xFF25D366) : scheme.onSurfaceVariant,
                          ),
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
                                  api: _api,
                                  tick: chatTick(
                                    mine: mine,
                                    id: message.id,
                                    peerDelivered: _peerDelivered,
                                    peerRead: _peerRead,
                                    status: message.status,
                                  ),
                                  onLink: _openLink,
                                  onLongPress: message.isVoice ? null : (details) => unawaited(_menu(message, details)),
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
              child: _recording
                  ? Row(
                      children: [
                        IconButton(
                          tooltip: 'Delete',
                          onPressed: () => unawaited(_finishVoice(send: false)),
                          icon: const Icon(Icons.delete_outline_rounded),
                        ),
                        const Icon(Icons.fiber_manual_record, size: 12, color: Color(0xFFE53935)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            chatClock(_recorder.shownMs),
                            style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFFE53935)),
                          ),
                        ),
                        _roundButton(tooltip: 'Send voice note', icon: Icons.send_rounded, onPressed: () => unawaited(_finishVoice(send: true))),
                      ],
                    )
                  : ValueListenableBuilder<TextEditingValue>(
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
                            const SizedBox(width: 6),
                            if (_sending)
                              const Padding(
                                padding: EdgeInsets.all(12),
                                child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
                              )
                            else if (canSend)
                              _roundButton(tooltip: 'Send', icon: Icons.send_rounded, onPressed: () => unawaited(_send()))
                            else if (!Plat.isWeb)
                              _roundButton(tooltip: 'Voice note', icon: Icons.mic_rounded, onPressed: () => unawaited(_startVoice())),
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

class ChatFace extends StatefulWidget {
  const ChatFace({super.key, required this.name, this.photoRev = 0, this.size = 48, this.online = false});

  final String name;
  final int photoRev;
  final double size;
  final bool online;

  @override
  State<ChatFace> createState() => _ChatFaceState();
}

class _ChatFaceState extends State<ChatFace> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = ChatPhotos.cached(widget.name, widget.photoRev);
    _load();
  }

  @override
  void didUpdateWidget(ChatFace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photoRev != widget.photoRev || oldWidget.name != widget.name) {
      _bytes = ChatPhotos.cached(widget.name, widget.photoRev);
      _load();
    }
  }

  void _load() {
    final rev = widget.photoRev;
    if (rev <= 0 || _bytes != null) return;
    ChatPhotos.fetch(widget.name, rev).then((bytes) {
      if (!mounted || widget.photoRev != rev || bytes == null) return;
      setState(() => _bytes = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ChatAvatar(name: widget.name, size: widget.size, bytes: _bytes, online: widget.online);
  }
}

class ChatAvatar extends StatelessWidget {
  const ChatAvatar({super.key, required this.name, this.size = 48, this.bytes, this.online = false});

  final String name;
  final double size;
  final Uint8List? bytes;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final avatar = CircleAvatar(
      radius: size / 2,
      backgroundColor: chatAvatarColor(name),
      backgroundImage: bytes == null ? null : MemoryImage(bytes!),
      child: bytes == null
          ? Text(
              chatInitial(name),
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: size * 0.38),
            )
          : null,
    );
    if (!online) return avatar;
    final dot = size * 0.28;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: dot,
              height: dot,
              decoration: BoxDecoration(
                color: const Color(0xFF25D366),
                shape: BoxShape.circle,
                border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2),
              ),
            ),
          ),
        ],
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

Widget _roundButton({required String tooltip, required IconData icon, required VoidCallback onPressed}) {
  return IconButton.filled(
    tooltip: tooltip,
    style: IconButton.styleFrom(backgroundColor: const Color(0xFF25D366), foregroundColor: Colors.white),
    onPressed: onPressed,
    icon: Icon(icon),
  );
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.mine,
    required this.api,
    required this.tick,
    required this.onLink,
    required this.onLongPress,
  });

  final ChatMessage message;
  final bool mine;
  final ChatApi api;
  final String tick;
  final ValueChanged<String> onLink;
  final ValueChanged<LongPressStartDetails>? onLongPress;

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
    final stamp = chatTickColor(tick, dark: dark);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cap = constraints.maxWidth * 0.78;
          final max = cap > 420 ? 420.0 : cap;
          return GestureDetector(
            onLongPressStart: onLongPress,
            child: Container(
              constraints: BoxConstraints(maxWidth: max),
              margin: const EdgeInsets.only(bottom: 2, top: 1),
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 3),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(8),
                  topRight: const Radius.circular(8),
                  bottomLeft: Radius.circular(mine ? 8 : 2),
                  bottomRight: Radius.circular(mine ? 2 : 8),
                ),
                boxShadow: dark ? null : const [BoxShadow(color: Color(0x14000000), blurRadius: 0.5, offset: Offset(0, 1))],
              ),
              child: IntrinsicWidth(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (message.isVoice)
                      ChatVoiceBubble(message: message, color: fg, api: api)
                    else
                      _LinkText(text: message.text, links: message.links, color: fg, linkColor: link, onLink: onLink),
                    const SizedBox(height: 1),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(time, style: TextStyle(fontSize: 11, color: stamp)),
                          if (tick.isNotEmpty) ...[
                            const SizedBox(width: 2),
                            Icon(
                              tick == 'sent' ? Icons.done_rounded : Icons.done_all_rounded,
                              size: 16,
                              color: stamp,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
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
    return Text.rich(
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
