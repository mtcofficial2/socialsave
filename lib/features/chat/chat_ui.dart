import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_drafts.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/features/chat/chat_live.dart';
import 'package:social_save/shared/widgets/app_snack.dart';

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
  static const _pinKey = 'chat.list.pins.v1';
  static const _unreadKey = 'chat.list.unread.v1';

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);
  static Set<String> archived = <String>{};
  static Set<String> muted = <String>{};
  static Set<String> pinned = <String>{};
  static Set<String> unreadMarks = <String>{};
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
    final clean = id.trim();
    if (clean.isEmpty) return;
    await ensure();
    // A notification mute writes this key from Android while the list is
    // open. Read it again so that write is not replaced by an older copy.
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    muted = (prefs.getStringList(_muteKey) ?? muted.toList()).toSet();
    if (on) {
      muted.add(clean);
    } else {
      muted.remove(clean);
    }
    await _write(_muteKey, muted.toList());
    revision.value++;
  }

  static Future<void> setPinned(String id, {required bool on, bool quiet = false}) async {
    final clean = id.trim();
    if (clean.isEmpty) return;
    await ensure();
    if (on) {
      pinned.add(clean);
      if (pinned.length > 20) {
        pinned = pinned.skip(pinned.length - 20).toSet();
      }
    } else {
      pinned.remove(clean);
    }
    await _write(_pinKey, pinned.toList());
    if (!quiet) revision.value++;
  }

  static Future<void> setUnreadMark(String id, {required bool on, bool quiet = false}) async {
    final clean = id.trim();
    if (clean.isEmpty) return;
    await ensure();
    if (on) {
      unreadMarks.add(clean);
    } else {
      unreadMarks.remove(clean);
    }
    await _write(_unreadKey, unreadMarks.toList());
    if (!quiet) revision.value++;
  }

  /// Copies pins and unread marks when the server actually sent those keys.
  static Future<void> takeServerFlags(List<ChatThreadSummary> items) async {
    await ensure();
    var changed = false;
    for (final item in items) {
      if (item.pinKnown && pinned.contains(item.id) != item.pinned) {
        if (item.pinned) {
          pinned.add(item.id);
        } else {
          pinned.remove(item.id);
        }
        changed = true;
      }
      if (item.markKnown && unreadMarks.contains(item.id) != item.marked) {
        if (item.marked) {
          unreadMarks.add(item.id);
        } else {
          unreadMarks.remove(item.id);
        }
        changed = true;
      }
    }
    if (!changed) return;
    await _write(_pinKey, pinned.toList());
    await _write(_unreadKey, unreadMarks.toList());
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
    pinned = (prefs.getStringList(_pinKey) ?? const <String>[]).toSet();
    unreadMarks = (prefs.getStringList(_unreadKey) ?? const <String>[]).toSet();
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

/// Quiet search pill. The app theme draws a box unless every border is set.
class ChatSearchField extends StatelessWidget {
  const ChatSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onSubmitted,
    this.focusNode,
    this.hintText = 'Search or start a chat',
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hintText;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    final dark = ChatUiTokens.dark(context);
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(22),
      borderSide: BorderSide.none,
    );
    return TextField(
      controller: controller,
      focusNode: focusNode,
      autocorrect: false,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      style: TextStyle(color: ChatUiTokens.text(dark), fontSize: 16),
      decoration: InputDecoration(
        hintText: hintText,
        prefixIcon: Icon(
          Icons.search_rounded,
          color: dark ? ChatUiTokens.timeDark : ChatUiTokens.timeLight,
        ),
        filled: true,
        isDense: true,
        fillColor: dark ? const Color(0xFF1F2C34) : const Color(0xFFF0F2F5),
        constraints: const BoxConstraints(minHeight: 44),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        border: border,
        enabledBorder: border,
        focusedBorder: border,
        disabledBorder: border,
        errorBorder: border,
        focusedErrorBorder: border,
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

class ChatEmptyGroups extends StatelessWidget {
  const ChatEmptyGroups({super.key, required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 72, 24, 24),
      child: Column(
        children: [
          Icon(Icons.groups_outlined, size: 48, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            'No groups yet',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Make a group, or join one with a code.',
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
            onPressed: onCreate,
            child: const Text('New group'),
          ),
        ],
      ),
    );
  }
}

/// Flat chat row. Typing state is local, so a typing tick does not rebuild
/// the whole inbox.
const double _chatRowHeight = 76;

class ChatListTile extends StatefulWidget {
  const ChatListTile({
    super.key,
    required this.item,
    required this.me,
    required this.selected,
    required this.avatar,
    required this.onOpen,
    required this.onProfile,
    required this.onDownload,
    required this.onArchive,
    required this.onMute,
    required this.onDelete,
    this.onRename,
    this.onPin,
    this.onUnread,
    required this.muted,
    required this.archived,
    this.failed = false,
  });

  final ChatThreadSummary item;
  final String me;
  final bool selected;
  final Widget avatar;
  final VoidCallback onOpen;
  final VoidCallback onProfile;
  final VoidCallback onDownload;
  final VoidCallback onArchive;
  final VoidCallback onMute;
  final VoidCallback onDelete;
  final VoidCallback? onRename;
  final VoidCallback? onPin;
  final VoidCallback? onUnread;
  final bool muted;
  final bool archived;
  final bool failed;

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

  Future<void> _menuAt(Offset global) async {
    final box = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        global & const Size(1, 1),
        Offset.zero & box.size,
      ),
      items: [
        const PopupMenuItem<String>(
          value: 'profile',
          child: Text('View profile'),
        ),
        PopupMenuItem<String>(
          value: 'mute',
          child: Text(
            widget.muted ? 'Unmute notifications' : 'Mute notifications',
          ),
        ),
        const PopupMenuItem<String>(
          value: 'download',
          child: Text('Download photo'),
        ),
        PopupMenuItem<String>(
          value: 'archive',
          child: Text(widget.archived ? 'Unarchive' : 'Archive'),
        ),
        if (widget.onRename != null)
          const PopupMenuItem<String>(value: 'rename', child: Text('Edit name')),
        PopupMenuItem<String>(
          value: 'pin',
          child: Text(widget.item.pinned ? 'Unpin chat' : 'Pin chat'),
        ),
        const PopupMenuItem<String>(value: 'unread', child: Text('Mark unread')),
        const PopupMenuItem<String>(value: 'delete', child: Text('Delete')),
      ],
    );
    if (!mounted || choice == null) return;
    _close();
    switch (choice) {
      case 'profile':
        widget.onProfile();
      case 'download':
        widget.onDownload();
      case 'archive':
        widget.onArchive();
      case 'mute':
        widget.onMute();
      case 'rename':
        widget.onRename?.call();
      case 'pin':
        widget.onPin?.call();
      case 'unread':
        widget.onUnread?.call();
      case 'delete':
        widget.onDelete();
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = ChatUiTokens.dark(context);
    final scheme = Theme.of(context).colorScheme;
    final baseColor = dark ? ChatUiTokens.canvasDark : scheme.surface;
    // Opaque, so the swipe actions underneath never show through.
    final rowColor = widget.selected
        ? Color.alphaBlend(
            ChatUiTokens.brand.withValues(alpha: dark ? 0.22 : 0.16),
            baseColor,
          )
        : baseColor;
    final showActions = _dragging || _drag != 0;
    return SizedBox(
      height: _chatRowHeight,
      child: Stack(
        children: [
          if (showActions)
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
                      tooltip: widget.muted
                          ? 'Unmute notifications'
                          : 'Mute notifications',
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
                      _close();
                      widget.onOpen();
                    },
                    onSecondaryTapDown: (details) =>
                        unawaited(_menuAt(details.globalPosition)),
                    onLongPress: () {
                      final row = context.findRenderObject() as RenderBox?;
                      final at = row == null
                          ? Offset.zero
                          : row.localToGlobal(row.size.center(Offset.zero));
                      unawaited(_menuAt(at));
                    },
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _RowBody(
                          item: widget.item,
                          me: widget.me,
                          live: _live,
                          avatar: widget.avatar,
                          muted: widget.muted,
                          failed: widget.failed,
                        ),
                        Positioned(
                          left: 80,
                          right: 0,
                          bottom: 0,
                          height: 0.6,
                          child: ColoredBox(
                            color: dark
                                ? const Color(
                                    0xFFAEBAC1,
                                  ).withValues(alpha: 0.16)
                                : const Color(0xFFE4E7EA),
                          ),
                        ),
                      ],
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
      height: _chatRowHeight,
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
    required this.failed,
  });

  final ChatThreadSummary item;
  final String me;
  final bool live;
  final Widget avatar;
  final bool muted;
  final bool failed;

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
    final preview = failed ? 'Not sent' : chatPreview(item.lastText, item.lastFrom, me);
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
                Row(
                  children: [
                    if (item.pinned) ...[
                      const Icon(Icons.push_pin, size: 14, color: ChatUiTokens.brand),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          letterSpacing: -0.2,
                          fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                if (recording || typing)
                  ChatActivityLine(recording: recording)
                else if (failed && draft.isEmpty)
                  Text(
                    'Not sent',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, height: 1.2, color: scheme.error),
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
                            fontSize: 14,
                            height: 1.2,
                            color: unread
                                ? scheme.onSurface
                                : scheme.onSurfaceVariant,
                            fontWeight: unread
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (stamp.isNotEmpty)
                Text(
                  stamp,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                    color: unread
                        ? ChatUiTokens.brand
                        : scheme.onSurfaceVariant,
                  ),
                ),
              if (muted) ...[
                if (stamp.isNotEmpty) const SizedBox(height: 4),
                Tooltip(
                  message: 'Notifications muted',
                  child: Icon(
                    Icons.notifications_off_rounded,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
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
          fontSize: 11,
          fontWeight: FontWeight.w600,
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
    required this.imeSends,
    required this.onKey,
    required this.onChanged,
    required this.onSend,
    required this.onMic,
    this.onMicHoldStart,
    this.onMicHoldMove,
    this.onMicHoldEnd,
    required this.onAttach,
    required this.onEmoji,
    required this.showMic,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  /// The on-screen Send key. A computer leaves this off so Shift+Enter
  /// can stay a new line while the Enter key is handled separately.
  final bool imeSends;
  final FocusOnKeyEventCallback onKey;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final VoidCallback onMic;
  final void Function(LongPressStartDetails)? onMicHoldStart;
  final void Function(LongPressMoveUpdateDetails)? onMicHoldMove;
  final void Function(LongPressEndDetails)? onMicHoldEnd;
  final VoidCallback onAttach;
  final VoidCallback onEmoji;
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
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Focus(
                        onKeyEvent: onKey,
                        child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          onChanged: onChanged,
                          minLines: 1,
                          maxLines: 5,
                          textInputAction: imeSends
                              ? TextInputAction.send
                              : TextInputAction.newline,
                          onSubmitted: imeSends ? (_) => onSend() : null,
                          style: TextStyle(
                            fontSize: 16,
                            height: 1.25,
                            color: ChatUiTokens.text(dark),
                          ),
                          decoration: const InputDecoration(
                            hintText: 'Message',
                            filled: false,
                            isDense: true,
                            contentPadding: EdgeInsets.fromLTRB(14, 10, 4, 10),
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
                    IconButton(
                      tooltip: 'Emoji',
                      onPressed: onEmoji,
                      icon: Icon(
                        Icons.emoji_emotions_outlined,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
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
                  ? onMicHoldStart == null
                  ? _RoundButton(
                      key: const ValueKey('mic'),
                      tooltip: 'Voice note',
                      icon: Icons.mic_rounded,
                      onPressed: onMic,
                    )
                  : GestureDetector(
                      key: const ValueKey('mic-hold'),
                      onTap: onMic,
                      onLongPressStart: onMicHoldStart,
                      onLongPressMoveUpdate: onMicHoldMove,
                      onLongPressEnd: onMicHoldEnd,
                      child: const SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(Icons.mic_rounded, color: ChatUiTokens.brand),
                      ),
                    )
                  : const SizedBox(width: 48, height: 48),
            ),
          ],
        );
      },
    );
  }
}

/// "typing" or "recording a voice note", with moving dots.
class ChatActivityLine extends StatefulWidget {
  const ChatActivityLine({super.key, required this.recording});

  final bool recording;

  @override
  State<ChatActivityLine> createState() => _ChatActivityLineState();
}

class _ChatActivityLineState extends State<ChatActivityLine>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dots;

  @override
  void initState() {
    super.initState();
    _dots = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _dots.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.recording ? 'recording a voice note' : 'typing';
    return AnimatedBuilder(
      animation: _dots,
      builder: (context, _) {
        final step = (_dots.value * 3).floor();
        final marks = step >= 2 ? 3 : step + 1;
        return Text(
          '$label${'.' * marks}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: ChatUiTokens.brand,
            fontStyle: FontStyle.italic,
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
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

/// Opens the chat for a written @username.
///
/// [leaveOverlay] pops the current route first. A status is shown on top of
/// the chat stack, so the new chat would stay hidden without that pop.
/// Returns true when a chat page was opened.
Future<bool> openUsernameChat(
  BuildContext context,
  String username, {
  String currentThreadId = '',
  bool leaveOverlay = false,
}) async {
  final name = username.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
  if (!RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(name)) return false;
  try {
    final opened = await ChatApi().openThread(name);
    if (!context.mounted) return false;
    if (currentThreadId.isNotEmpty && opened.id == currentThreadId) return false;
    final router = GoRouter.of(context);
    if (leaveOverlay) {
      final nav = Navigator.of(context);
      if (nav.canPop()) nav.pop();
    }
    await router.push(
      '/chat/${opened.id}',
      extra: ChatThreadTarget(username: opened.username, name: opened.name),
    );
    return true;
  } catch (error) {
    if (context.mounted) {
      AppSnack.error(context, chatErrorText(error));
    }
    return false;
  }
}

/// Message or status text. Web links and @usernames are underlined and tappable.
class ChatTapText extends StatelessWidget {
  const ChatTapText({
    super.key,
    required this.text,
    required this.color,
    this.links = const [],
    this.linkColor,
    this.onLink,
    this.onUsername,
    this.reserve = 0,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.highlight = '',
  });

  final String text;
  final List<String> links;
  final Color color;
  final Color? linkColor;
  final ValueChanged<String>? onLink;
  final ValueChanged<String>? onUsername;
  final double reserve;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final String highlight;

  List<InlineSpan> _marked(String text, TextStyle style) {
    final needle = highlight.trim();
    if (needle.isEmpty) return [TextSpan(text: text, style: style)];
    final lower = text.toLowerCase();
    final look = needle.toLowerCase();
    final spans = <InlineSpan>[];
    var cursor = 0;
    while (cursor < text.length) {
      final at = lower.indexOf(look, cursor);
      if (at < 0) {
        spans.add(TextSpan(text: text.substring(cursor), style: style));
        break;
      }
      if (at > cursor) spans.add(TextSpan(text: text.substring(cursor, at), style: style));
      spans.add(TextSpan(
        text: text.substring(at, at + look.length),
        style: style.copyWith(backgroundColor: const Color(0xFFFFF59D), color: const Color(0xFF111B21)),
      ));
      cursor = at + look.length;
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final base = style ?? TextStyle(fontSize: 15.5, height: 1.3, color: color);
    final tapColor = linkColor ?? color;
    final tapStyle = base.copyWith(
      color: tapColor,
      decoration: TextDecoration.underline,
      decorationColor: tapColor,
    );
    final pieces = chatTextPieces(text, links);
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          for (final piece in pieces)
            if (piece.isLink || (piece.isUsername && onUsername != null))
              WidgetSpan(
                alignment: PlaceholderAlignment.baseline,
                baseline: TextBaseline.alphabetic,
                child: GestureDetector(
                  onTap: () {
                    if (piece.isLink) {
                      onLink?.call(piece.link!);
                    } else {
                      onUsername?.call(piece.username!);
                    }
                  },
                  child: Text.rich(TextSpan(children: _marked(piece.text, tapStyle))),
                ),
              )
            else
              ..._marked(piece.text, base),
          if (reserve > 0) WidgetSpan(child: SizedBox(width: reserve, height: 14)),
        ],
      ),
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
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
