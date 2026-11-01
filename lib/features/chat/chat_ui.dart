import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_drafts.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/features/chat/chat_live.dart';

/// Colors, radii, and spacing for chat. These match the chat canvas we
/// already ship. Nothing here is a third-party brand mark.
class ChatUiTokens {
  const ChatUiTokens._();

  static const Color brand = Color(0xFF25D366);
  static const Color outgoingLight = Color(0xFFD9FDD3);
  static const Color outgoingDark = Color(0xFF005C4B);
  static const Color incomingDark = Color(0xFF202C33);
  static const Color canvasLight = Color(0xFFEFE7DE);
  static const Color canvasDark = Color(0xFF0B141A);
  static const Color textLight = Color(0xFF111B21);
  static const Color textDark = Color(0xFFE9EDEF);
  static const Color timeLight = Color(0xFF667781);
  static const Color timeDark = Color(0xFFAEBAC1);
  static const Color linkLight = Color(0xFF027EB5);
  static const Color linkDark = Color(0xFF53BDEB);
  static const Color fieldDark = Color(0xFF1F2C34);

  static const double avatar = 56;
  static const double bubbleMax = 0.78;
  static const double pill = 24;
  static const double radius = 8;
  static const double tightRadius = 6;

  static bool dark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static Color canvas(bool dark) => dark ? canvasDark : canvasLight;
  static Color outgoing(bool dark) => dark ? outgoingDark : outgoingLight;
  static Color incoming(bool dark) => dark ? incomingDark : Colors.white;
  static Color text(bool dark) => dark ? textDark : textLight;
  static Color time(bool dark) => dark ? timeDark : timeLight;
  static Color link(bool dark) => dark ? linkDark : linkLight;
  static Color field(bool dark) => dark ? fieldDark : Colors.white;
  static Color searchFill(bool dark) => dark ? fieldDark : Colors.white;
}

/// Local list choices. Archive and mute stay on this phone. A hidden chat
/// comes back when a newer message arrives, so a delete cannot swallow it.
class ChatInboxFilter {
  ChatInboxFilter._();

  static const _archiveKey = 'chat.list.archived.v1';
  static const _muteKey = 'chat.list.muted.v1';
  static const _hideKey = 'chat.list.hidden.v1';

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);
  static Set<String> archived = <String>{};
  static Set<String> muted = <String>{};
  static final Map<String, int> hidden = <String, int>{};
  static Future<void>? _loading;

  static Future<void> ensure() {
    return _loading ??= _read();
  }

  static bool isMuted(String id) => muted.contains(id);

  static bool hides(String id, int lastId) {
    final at = hidden[id];
    if (at == null) return false;
    return lastId <= at;
  }

  static Future<void> setArchived(String id, {required bool on}) async {
    await ensure();
    if (on) {
      archived.add(id);
    } else {
      archived.remove(id);
    }
    await _write(_archiveKey, archived.toList());
    revision.value++;
  }

  static Future<void> setMuted(String id, {required bool on}) async {
    await ensure();
    if (on) {
      muted.add(id);
    } else {
      muted.remove(id);
    }
    await _write(_muteKey, muted.toList());
    revision.value++;
  }

  static Future<void> hide(String id, int lastId) async {
    await ensure();
    hidden[id] = lastId < 0 ? 0 : lastId;
    archived.remove(id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hideKey, [
      for (final entry in hidden.entries) '${entry.key}:${entry.value}',
    ]);
    await _write(_archiveKey, archived.toList());
    revision.value++;
  }

  static Future<void> _read() async {
    final prefs = await SharedPreferences.getInstance();
    archived = (prefs.getStringList(_archiveKey) ?? const <String>[]).toSet();
    muted = (prefs.getStringList(_muteKey) ?? const <String>[]).toSet();
    hidden.clear();
    for (final raw in prefs.getStringList(_hideKey) ?? const <String>[]) {
      final cut = raw.lastIndexOf(':');
      if (cut <= 0) continue;
      final id = raw.substring(0, cut);
      final last = int.tryParse(raw.substring(cut + 1)) ?? 0;
      if (id.isEmpty) continue;
      hidden[id] = last;
    }
    revision.value++;
  }

  static Future<void> _write(String key, List<String> values) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(key, values);
  }
}

/// Search field with no outline. The app theme draws a box unless every
/// border is cleared.
class ChatSearchField extends StatelessWidget {
  const ChatSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onSubmitted,
    this.focusNode,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    final dark = ChatUiTokens.dark(context);
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autocorrect: false,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      style: TextStyle(color: ChatUiTokens.text(dark), fontSize: 16),
      decoration: InputDecoration(
        hintText: 'Search or start a chat',
        prefixIcon: const Icon(Icons.search_rounded),
        filled: true,
        isDense: true,
        fillColor: ChatUiTokens.searchFill(dark),
        constraints: const BoxConstraints(minHeight: 48),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        errorBorder: InputBorder.none,
        focusedErrorBorder: InputBorder.none,
      ),
    );
  }
}

class ChatEmptyInbox extends StatelessWidget {
  const ChatEmptyInbox({super.key, required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 72, 24, 24),
      child: Column(
        children: [
          Icon(Icons.forum_outlined, size: 48, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            'No chats yet',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Start a chat with a username.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: ChatUiTokens.brand,
              foregroundColor: Colors.white,
              minimumSize: const Size(48, 48),
            ),
            onPressed: onStart,
            child: const Text('Start a chat'),
          ),
        ],
      ),
    );
  }
}

/// Flat chat row. Typing state is local, so a typing tick does not rebuild
/// the whole inbox.
class ChatListTile extends StatefulWidget {
  const ChatListTile({
    super.key,
    required this.item,
    required this.me,
    required this.selected,
    required this.avatar,
    required this.onOpen,
    required this.onArchive,
    required this.onMute,
    required this.onDelete,
    required this.muted,
    required this.archived,
  });

  final ChatThreadSummary item;
  final String me;
  final bool selected;
  final Widget avatar;
  final VoidCallback onOpen;
  final VoidCallback onArchive;
  final VoidCallback onMute;
  final VoidCallback onDelete;
  final bool muted;
  final bool archived;

  @override
  State<ChatListTile> createState() => _ChatListTileState();
}

class _ChatListTileState extends State<ChatListTile> {
  static const double _reveal = 168;
  double _drag = 0;
  bool _dragging = false;
  bool _live = false;
  Timer? _liveTimer;

  @override
  void initState() {
    super.initState();
    _live = _isLive;
    ChatLive.revision.addListener(_onLive);
    if (_live) _arm();
  }

  @override
  void didUpdateWidget(ChatListTile old) {
    super.didUpdateWidget(old);
    if (old.item.id != widget.item.id) {
      _live = _isLive;
      _arm();
    }
  }

  @override
  void dispose() {
    ChatLive.revision.removeListener(_onLive);
    _liveTimer?.cancel();
    super.dispose();
  }

  bool get _isLive =>
      ChatLive.isTyping(widget.item.id) || ChatLive.isRecording(widget.item.id);

  void _onLive() {
    final live = _isLive;
    if (live == _live && !live) return;
    if (!mounted) return;
    setState(() => _live = live);
    _arm();
  }

  void _arm() {
    _liveTimer?.cancel();
    if (!_live) return;
    _liveTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      final live = _isLive;
      if (live == _live) return;
      setState(() => _live = live);
    });
  }

  void _close() {
    setState(() {
      _dragging = false;
      _drag = 0;
    });
  }

  Future<void> _menu(TapDownDetails details) async {
    final box = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        details.globalPosition & const Size(1, 1),
        Offset.zero & box.size,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'archive',
          child: Text(widget.archived ? 'Unarchive' : 'Archive'),
        ),
        PopupMenuItem<String>(
          value: 'mute',
          child: Text(widget.muted ? 'Unmute' : 'Mute'),
        ),
        const PopupMenuItem<String>(value: 'delete', child: Text('Delete')),
      ],
    );
    if (!mounted || choice == null) return;
    _close();
    switch (choice) {
      case 'archive':
        widget.onArchive();
      case 'mute':
        widget.onMute();
      case 'delete':
        widget.onDelete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = ChatUiTokens.dark(context);
    final scheme = Theme.of(context).colorScheme;
    final rowColor = widget.selected
        ? ChatUiTokens.brand.withValues(alpha: dark ? 0.22 : 0.16)
        : (dark ? ChatUiTokens.canvasDark : scheme.surface);
    return SizedBox(
      height: 72,
      child: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(
              color: dark ? const Color(0xFF111B21) : const Color(0xFFF0F2F5),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _SwipeAction(
                    tooltip: widget.archived ? 'Unarchive' : 'Archive',
                    icon: widget.archived
                        ? Icons.unarchive_outlined
                        : Icons.archive_outlined,
                    color: const Color(0xFF53BDEB),
                    onPressed: () {
                      _close();
                      widget.onArchive();
                    },
                  ),
                  _SwipeAction(
                    tooltip: widget.muted ? 'Unmute' : 'Mute',
                    icon: widget.muted
                        ? Icons.notifications_off_outlined
                        : Icons.notifications_none_rounded,
                    color: const Color(0xFF8696A0),
                    onPressed: () {
                      _close();
                      widget.onMute();
                    },
                  ),
                  _SwipeAction(
                    tooltip: 'Delete',
                    icon: Icons.delete_outline_rounded,
                    color: const Color(0xFFEF5350),
                    onPressed: () {
                      _close();
                      widget.onDelete();
                    },
                  ),
                ],
              ),
            ),
          ),
          Positioned.fill(
            child: GestureDetector(
              // A mouse click was counted as a swipe and uncovered Archive,
              // Mute, and Delete. Only a finger can slide the row.
              supportedDevices: const <PointerDeviceKind>{
                PointerDeviceKind.touch,
                PointerDeviceKind.stylus,
                PointerDeviceKind.invertedStylus,
              },
              onHorizontalDragStart: (_) => _dragging = true,
              onHorizontalDragUpdate: (details) {
                setState(() {
                  _dragging = true;
                  _drag = (_drag + details.delta.dx).clamp(-_reveal, 0);
                });
              },
              onHorizontalDragEnd: (_) {
                setState(() {
                  _dragging = false;
                  _drag = _drag < -_reveal / 2 ? -_reveal : 0;
                });
              },
              child: AnimatedContainer(
                duration: _dragging
                    ? Duration.zero
                    : const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                transform: Matrix4.translationValues(_drag, 0, 0),
                child: Material(
                  color: rowColor,
                  child: InkWell(
                    onTap: () {
                      if (_drag != 0) {
                        _close();
                        return;
                      }
                      widget.onOpen();
                    },
                    onSecondaryTapDown: _menu,
                    child: _RowBody(
                      item: widget.item,
                      me: widget.me,
                      live: _live,
                      avatar: widget.avatar,
                      muted: widget.muted,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwipeAction extends StatelessWidget {
  const _SwipeAction({
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      height: 72,
      child: ColoredBox(
        color: color,
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(icon, color: Colors.white),
        ),
      ),
    );
  }
}

class _RowBody extends StatelessWidget {
  const _RowBody({
    required this.item,
    required this.me,
    required this.live,
    required this.avatar,
    required this.muted,
  });

  final ChatThreadSummary item;
  final String me;
  final bool live;
  final Widget avatar;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unread = item.unread > 0;
    final stamp = item.lastAt == null
        ? ''
        : chatListStamp(
            item.lastAt!,
            DateTime.now(),
            TimeOfDay.fromDateTime(item.lastAt!.toLocal()).format(context),
          );
    final draft = ChatDrafts.peek(item.id).trim();
    final recording = live && ChatLive.isRecording(item.id);
    final typing = live && !recording && ChatLive.isTyping(item.id);
    final preview = chatPreview(item.lastText, item.lastFrom, me);
    final voice = draft.isEmpty && item.lastText.trim() == 'Voice message';
    final photo = draft.isEmpty && item.lastText.trim() == 'Photo';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          avatar,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.username,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: unread ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                if (recording)
                  const Text(
                    'recording audio…',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: ChatUiTokens.brand,
                      fontStyle: FontStyle.italic,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                else if (typing)
                  const Text(
                    'typing…',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: ChatUiTokens.brand,
                      fontStyle: FontStyle.italic,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                else if (draft.isNotEmpty)
                  Text.rich(
                    TextSpan(
                      children: [
                        const TextSpan(
                          text: 'Draft: ',
                          style: TextStyle(
                            color: ChatUiTokens.brand,
                            fontStyle: FontStyle.italic,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        TextSpan(
                          text: draft,
                          style: TextStyle(
                            fontStyle: FontStyle.italic,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                else
                  Row(
                    children: [
                      if (item.lastFrom == me && item.lastStatus.isNotEmpty) ...[
                        Icon(
                          item.lastStatus == 'sent'
                              ? Icons.done_rounded
                              : Icons.done_all_rounded,
                          size: 16,
                          color: chatTickColor(
                            item.lastStatus,
                            dark: ChatUiTokens.dark(context),
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      if (voice)
                        Icon(
                          Icons.mic_rounded,
                          size: 16,
                          color: unread
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant,
                        ),
                      if (photo)
                        Icon(
                          Icons.photo_outlined,
                          size: 16,
                          color: unread
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant,
                        ),
                      if (voice || photo) const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: unread
                                ? scheme.onSurface
                                : scheme.onSurfaceVariant,
                            fontWeight: unread
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (stamp.isNotEmpty || muted)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (muted) ...[
                      Icon(
                        Icons.notifications_off_outlined,
                        size: 15,
                        color: scheme.onSurfaceVariant,
                      ),
                      if (stamp.isNotEmpty) const SizedBox(width: 4),
                    ],
                    if (stamp.isNotEmpty)
                      Text(
                        stamp,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                          color: unread
                              ? ChatUiTokens.brand
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              if (unread) ...[
                const SizedBox(height: 6),
                _CountBadge(count: item.unread),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: ChatUiTokens.brand,
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// Pill composer. The outline from the app theme is turned off on every border.
class ChatComposer extends StatelessWidget {
  const ChatComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.enterSends,
    required this.onKey,
    required this.onChanged,
    required this.onSend,
    required this.onMic,
    required this.onAttach,
    required this.showMic,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enterSends;
  final FocusOnKeyEventCallback onKey;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final VoidCallback onMic;
  final VoidCallback onAttach;
  final bool showMic;

  @override
  Widget build(BuildContext context) {
    final dark = ChatUiTokens.dark(context);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final canSend = value.text.trim().isNotEmpty;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: 'Attach',
              onPressed: onAttach,
              icon: Icon(
                Icons.add_rounded,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                size: 26,
              ),
              style: IconButton.styleFrom(
                minimumSize: const Size(48, 48),
                fixedSize: const Size(48, 48),
              ),
            ),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: ChatUiTokens.field(dark),
                  borderRadius: BorderRadius.circular(ChatUiTokens.pill),
                ),
                child: Focus(
                  onKeyEvent: onKey,
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    onChanged: onChanged,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: enterSends
                        ? TextInputAction.newline
                        : TextInputAction.send,
                    onSubmitted: enterSends ? null : (_) => onSend(),
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.25,
                      color: ChatUiTokens.text(dark),
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Message',
                      filled: false,
                      isDense: true,
                      contentPadding: EdgeInsets.fromLTRB(14, 10, 14, 10),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 140),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeOut,
              child: canSend
                  ? _RoundButton(
                      key: const ValueKey('send'),
                      tooltip: 'Send',
                      icon: Icons.send_rounded,
                      onPressed: onSend,
                    )
                  : showMic
                  ? _RoundButton(
                      key: const ValueKey('mic'),
                      tooltip: 'Voice note',
                      icon: Icons.mic_rounded,
                      onPressed: onMic,
                    )
                  : const SizedBox(width: 48, height: 48),
            ),
          ],
        );
      },
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filled(
      tooltip: tooltip,
      style: IconButton.styleFrom(
        backgroundColor: ChatUiTokens.brand,
        foregroundColor: Colors.white,
        fixedSize: const Size(48, 48),
        minimumSize: const Size(48, 48),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 22),
    );
  }
}

class ChatDownChip extends StatelessWidget {
  const ChatDownChip({super.key, required this.count, required this.onPressed});

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : '$count';
    return Material(
      color: ChatUiTokens.dark(context)
          ? ChatUiTokens.incomingDark
          : Colors.white,
      elevation: 2,
      shadowColor: const Color(0x33000000),
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.keyboard_arrow_down_rounded,
                color: ChatUiTokens.brand,
              ),
              Text(
                label,
                style: const TextStyle(
                  color: ChatUiTokens.brand,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ChatDayPill extends StatelessWidget {
  const ChatDayPill({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final dark = ChatUiTokens.dark(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: (dark ? ChatUiTokens.incomingDark : Colors.white).withValues(
              alpha: 0.92,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: ChatUiTokens.time(dark),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
