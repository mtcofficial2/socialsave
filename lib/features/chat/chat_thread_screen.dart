import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/chat/chat_alerts.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_drafts.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/features/chat/chat_history.dart';
import 'package:social_save/features/chat/chat_image_store.dart';
import 'package:social_save/features/chat/chat_link.dart';
import 'package:social_save/features/chat/chat_live.dart';
import 'package:social_save/features/chat/chat_profile.dart';
import 'package:social_save/features/chat/chat_ui.dart';
import 'package:social_save/features/chat/chat_voice.dart';
import 'package:social_save/features/chat/chat_wallpaper.dart';

/// A direct chat. On a phone this is its own page. On a wide window it sits
/// beside the chat list.
class ChatThreadScreen extends StatelessWidget {
  const ChatThreadScreen({
    super.key,
    required this.threadId,
    required this.username,
    this.seenName = '',
    this.group = false,
  });

  final String threadId;
  final String username;

  /// Private name for this chat. Blank shows [username].
  final String seenName;

  /// A group chat. The title is the group name, not a username.
  final bool group;

  @override
  Widget build(BuildContext context) {
    return ChatThreadView(
      threadId: threadId,
      username: username,
      seenName: seenName,
      group: group || threadId.startsWith('g'),
    );
  }
}

class ChatThreadView extends StatefulWidget {
  const ChatThreadView({
    super.key,
    required this.threadId,
    required this.username,
    this.seenName = '',
    this.group = false,
    this.embedded = false,
    this.onRead,
    this.onSeenName,
    this.onLeft,
  });

  final String threadId;
  final String username;
  final String seenName;
  final bool group;
  final bool embedded;
  final void Function(String threadId, int lastId)? onRead;
  final void Function(String threadId, String name)? onSeenName;
  final void Function(String threadId)? onLeft;

  @override
  State<ChatThreadView> createState() => _ChatThreadViewState();
}

class _ChatThreadViewState extends State<ChatThreadView>
    with WidgetsBindingObserver {
  final ChatApi _api = ChatApi();
  // The server can lose a chat (restart without storage) and hand out a new
  // id for the same person, so the id can change while the screen is open.
  late String _threadId = widget.threadId;
  late String _seenName = widget.seenName;
  late bool _group = widget.group || widget.threadId.startsWith('g');
  bool _reopening = false;
  final ChatRecorder _recorder = ChatRecorder();
  final TextEditingController _text = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();
  List<ChatMessage> _messages = const [];
  Timer? _poll;
  String _me = '';
  String? _error;
  bool _starting = true;
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
  Timer? _draftTimer;
  Timer? _typingIdle;
  Timer? _typingClock;
  StreamSubscription<ChatLiveEvent>? _live;
  final Map<int, GlobalKey> _rowKeys = {};
  int _localSeq = 0;
  int? _replyId;
  String _replyName = '';
  String _replyText = '';
  final Set<int> _selected = <int>{};
  final TextEditingController _search = TextEditingController();
  bool _searching = false;
  bool _blocked = false;
  List<int> _pinned = const [];
  List<String> _members = const [];
  int _syncedAt = 0;
  int? _editingId;
  int _pinCursor = 0;

  bool get _isGroup => _group || widget.group || _threadId.startsWith('g');

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
  void didUpdateWidget(ChatThreadView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.seenName != oldWidget.seenName) _seenName = widget.seenName;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ChatAlerts.holdThread(_threadId);
    _live = ChatLive.instance.events.listen(_onLive);
    ChatLive.revision.addListener(_onTypingClock);
    _scroll.addListener(_onScroll);
    _text.addListener(_onDraftChanged);
    _recorder.onLimit = () {
      if (!mounted) return;
      unawaited(_finishVoice(send: true));
    };
    unawaited(_open());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ChatAlerts.releaseThread(_threadId);
    _live?.cancel();
    ChatLive.revision.removeListener(_onTypingClock);
    ChatLive.instance.typing(_threadId, on: false);
    ChatLive.instance.recording(_threadId, on: false);
    _poll?.cancel();
    _draftTimer?.cancel();
    _typingIdle?.cancel();
    _typingClock?.cancel();
    _text.removeListener(_onDraftChanged);
    final pendingDraft = _text.text;
    final threadId = _threadId;
    unawaited(ChatDrafts.write(threadId, pendingDraft));
    unawaited(_recorder.dispose());
    _scroll.removeListener(_onScroll);
    _text.dispose();
    _search.dispose();
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

  void _onDraftChanged() {
    _draftTimer?.cancel();
    final threadId = _threadId;
    final text = _text.text;
    _draftTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(ChatDrafts.write(threadId, text));
    });
    if (_focus.hasFocus) _noteTyping();
  }

  void _onTyped(String _) {
    _noteTyping(force: true);
  }

  void _noteTyping({bool force = false}) {
    if (!force && !_focus.hasFocus) return;
    final on = _text.text.trim().isNotEmpty;
    ChatLive.instance.typing(_threadId, on: on);
    _typingIdle?.cancel();
    if (!on) return;
    _typingIdle = Timer(const Duration(seconds: 3), () {
      ChatLive.instance.typing(_threadId, on: false);
    });
  }

  void _onTypingClock() {
    if (!mounted) return;
    setState(() {});
    _typingClock?.cancel();
    final live =
        ChatLive.isTyping(_threadId) ||
        ChatLive.isRecording(_threadId);
    if (!live) return;
    _typingClock = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() {});
    });
  }

  void _onLive(ChatLiveEvent event) {
    if (!mounted || event.type == 'typing' || event.type == 'recording') {
      return;
    }
    if (event.type == 'presence') {
      final peer = widget.username
          .replaceFirst(RegExp(r'^@'), '')
          .trim()
          .toLowerCase();
      if (peer.isEmpty || event.from.trim().toLowerCase() != peer) return;
      setState(() {
        _peerOnline = event.on;
        if (event.at > 0) {
          _peerSeen = DateTime.fromMillisecondsSinceEpoch(event.at);
        }
      });
      _remember();
      if (event.on) {
        for (final message in _messages) {
          if (!message.isPhoto || message.photo.isEmpty) continue;
          if (message.localBytes != null) continue;
          ChatLive.instance.wantPhoto(_threadId, message.photo);
        }
      }
      return;
    }
    if (event.threadId != _threadId) return;
    if (event.type == 'removed') {
      if (event.id > 0) _drop(event.id);
      return;
    }
    if (event.type == 'pinned') {
      setState(() => _pinned = event.pinned);
      return;
    }
    if ((event.type == 'message' ||
            event.type == 'reaction' ||
            event.type == 'edited') &&
        event.message != null) {
      _ingest(event.message!);
      return;
    }
    if (event.type == 'delivered' && event.id > _peerDelivered) {
      setState(() => _peerDelivered = event.id);
      _remember();
      return;
    }
    if (event.type == 'read' && event.id > 0) {
      setState(() {
        if (event.id > _peerRead) _peerRead = event.id;
        if (event.id > _peerDelivered) _peerDelivered = event.id;
      });
      _remember();
    }
  }

  List<ChatMessage> _mergeOpen(List<ChatMessage> saved, List<ChatMessage> live) {
    if (live.isEmpty) return saved;
    final ids = {for (final item in saved) item.id};
    return [
      ...saved,
      for (final item in live)
        if (!ids.contains(item.id)) item,
    ];
  }

  void _remember() {
    if (_me.isEmpty || _threadId.isEmpty) return;
    unawaited(
      ChatHistory.saveLog(
        username: _me,
        threadId: _threadId,
        messages: _messages,
        delivered: _peerDelivered,
        read: _peerRead,
        seen: _peerSeen,
        photoRev: _peerPhoto,
      ),
    );
  }

  GlobalKey _keyFor(int id) => _rowKeys.putIfAbsent(id, GlobalKey.new);

  void _scrollToMessage(int id) {
    final current = _rowKeys[id]?.currentContext;
    if (current != null) {
      unawaited(
        Scrollable.ensureVisible(
          current,
          duration: const Duration(milliseconds: 220),
          alignment: 0.2,
        ),
      );
      return;
    }
    final index = _messages.indexWhere((item) => item.id == id);
    if (index < 0 || !_scroll.hasClients) return;
    final fraction = index / _messages.length;
    final target = _scroll.position.maxScrollExtent * fraction;
    _scroll.jumpTo(target.clamp(0, _scroll.position.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final next = _rowKeys[id]?.currentContext;
      if (next == null) return;
      unawaited(
        Scrollable.ensureVisible(
          next,
          duration: const Duration(milliseconds: 180),
          alignment: 0.2,
        ),
      );
    });
  }

  Future<void> _open() async {
    _me = await ChatSession.username();
    final saved = await ChatDrafts.read(_threadId);
    if (!mounted) return;
    if (saved.isNotEmpty && _text.text.isEmpty) {
      _text.value = TextEditingValue(
        text: saved,
        selection: TextSelection.collapsed(offset: saved.length),
      );
    }
    final seen = await ChatReads.load();
    _seenAtOpen = seen[_threadId] ?? 0;
    if (!mounted) return;
    if (_threadId.isEmpty) {
      setState(() {
        _starting = false;
        _error = 'That chat was not found.';
      });
      return;
    }
    final savedLog = _me.isEmpty
        ? null
        : await ChatHistory.log(_me, _threadId);
    if (!mounted) return;
    if (savedLog != null && savedLog.messages.isNotEmpty) {
      final merged = _mergeOpen(savedLog.messages, _messages);
      var after = _after;
      var seq = _localSeq;
      for (final message in merged) {
        if (message.id > after) after = message.id;
        if (message.id < seq) seq = message.id;
      }
      setState(() {
        _messages = merged;
        _after = after;
        _localSeq = seq;
        _peerDelivered = savedLog.delivered;
        _peerRead = savedLog.read;
        _peerSeen = savedLog.seen;
        _peerPhoto = savedLog.photoRev;
        _peerOnline = false;
        _starting = false;
        _error = null;
      });
      _jump(animate: false);
      _remember();
      unawaited(_noteRead());
    }
    await _refresh();
    if (!mounted || _threadId.isEmpty) return;
    _startPoll();
  }

  void _startPoll() {
    _poll?.cancel();
    if (_threadId.isEmpty) return;
    _poll = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;
      unawaited(_refresh());
    });
  }

  Future<void> _refresh() async {
    if (_refreshing || _threadId.isEmpty) return;
    _refreshing = true;
    try {
      final started = DateTime.now().millisecondsSinceEpoch;
      var sync = await _api.messages(_threadId, _after, since: _syncedAt);
      if (!mounted) return;
      if (sync.lastId >= 0 && sync.lastId < _after) {
        // The server's history is shorter than ours, so it lost or rolled
        // back messages. Start the cursor again or new ones are skipped.
        _forgetServerMessages();
        sync = await _api.messages(_threadId, 0);
        if (!mounted) return;
      }
      _syncedAt = started;
      final nameChanged = sync.peerName != _seenName;
      final presenceChanged =
          sync.peerDelivered != _peerDelivered ||
          sync.peerRead != _peerRead ||
          sync.peerOnline != _peerOnline ||
          sync.peerPhotoRev != _peerPhoto ||
          sync.peerLastSeen != _peerSeen ||
          sync.peerBlocked != _blocked ||
          sync.peerGroup != _group ||
          sync.peerMembers.join('\n') != _members.join('\n') ||
          sync.pinned.join(',') != _pinned.join(',') ||
          nameChanged;
      _peerDelivered = sync.peerDelivered;
      _peerRead = sync.peerRead;
      _peerOnline = sync.peerOnline;
      _peerSeen = sync.peerLastSeen;
      _peerPhoto = sync.peerPhotoRev;
      _seenName = sync.peerName;
      if (sync.peerGroup) _group = true;
      _blocked = sync.peerBlocked;
      _members = sync.peerMembers;
      _pinned = sync.pinned;
      if (nameChanged) widget.onSeenName?.call(_threadId, sync.peerName);
      final gone = sync.removed.toSet();
      if (gone.isNotEmpty) {
        final before = _messages.length;
        _messages = [
          for (final item in _messages)
            if (!gone.contains(item.id)) item,
        ];
        if (_me.isNotEmpty) {
          unawaited(
            ChatHistory.hide(
              username: _me,
              threadId: _threadId,
              ids: gone,
            ),
          );
        }
        if (before != _messages.length && mounted) setState(() {});
      }
      final incoming = [
        for (final item in sync.messages)
          if (!gone.contains(item.id)) item,
      ];
      final keptLocal = <int>{};
      final consumed = <int>{};
      final matchedLocal = <int, ChatMessage>{};
      for (final local in _messages) {
        if (local.id >= 0) continue;
        ChatMessage? match;
        for (final server in incoming) {
          if (consumed.contains(server.id)) continue;
          if (_sameOutgoing(local, server)) {
            match = server;
            break;
          }
        }
        if (match == null) {
          keptLocal.add(local.id);
        } else {
          consumed.add(match.id);
          matchedLocal[match.id] = local;
        }
      }
      final known = {
        for (final item in _messages)
          if (item.id >= 0) item.id,
      };
      final fresh = <ChatMessage>[
        for (final item in incoming)
          if (!known.contains(item.id))
            matchedLocal[item.id] == null
                ? item
                : item.withQuoteFrom(matchedLocal[item.id]!),
      ];
      final base = [
        for (final item in _messages)
          if (item.id >= 0 || keptLocal.contains(item.id)) item,
      ];
      var next = _after;
      for (final item in fresh) {
        if (item.id > next) next = item.id;
      }
      final combined = [...base, ...fresh];
      var touched = false;
      for (final update in sync.updates) {
        if (gone.contains(update.id)) continue;
        final index = combined.indexWhere((item) => item.id == update.id);
        if (index < 0) {
          combined.add(update);
          touched = true;
          continue;
        }
        final next = update.withQuoteFrom(combined[index]);
        if (next.text != combined[index].text ||
            next.editedAt != combined[index].editedAt ||
            next.reactions.length != combined[index].reactions.length) {
          combined[index] = next;
          touched = true;
        }
      }
      final changed =
          fresh.isNotEmpty || base.length != _messages.length || touched;
      if (!changed && !_starting) {
        if (presenceChanged || _error != null) setState(() => _error = null);
        if (presenceChanged) _remember();
        unawaited(_noteRead());
        return;
      }
      final wasStarting = _starting;
      final stick = _stickToEnd || wasStarting;
      if (wasStarting) {
        final hasUnread = fresh.any(
          (item) => item.name != _me && item.id > _seenAtOpen,
        );
        _bannerAfter = hasUnread ? _seenAtOpen : -1;
      }
      setState(() {
        _messages = combined;
        _after = next;
        _error = null;
        _starting = false;
        if (!stick) {
          _below += fresh
              .where((item) => item.name != _me && item.id > 0)
              .length;
        }
      });
      if (stick) _jump(animate: !wasStarting && fresh.isNotEmpty);
      _remember();
      unawaited(_noteRead());
    } catch (error) {
      if (!mounted) return;
      if (_chatGone(error) && await _reopen()) {
        _refreshing = false;
        return _refresh();
      }
      setState(() {
        _starting = false;
        _error = _messages.isEmpty ? chatErrorText(error) : null;
      });
    } finally {
      _refreshing = false;
    }
  }

  bool _chatGone(Object error) =>
      chatErrorText(error).toLowerCase().contains('chat was not found');

  void _forgetServerMessages() {
    _messages = [
      for (final item in _messages)
        if (item.id < 0) item,
    ];
    _after = 0;
    _peerDelivered = 0;
    _peerRead = 0;
    _readSent = 0;
  }

  /// Opens the chat again by username when the server no longer knows this
  /// id. Returns true when there is a new id to use.
  Future<bool> _reopen() async {
    final peer = widget.username.replaceFirst(RegExp(r'^@'), '').trim();
    if (_reopening || peer.isEmpty) return false;
    _reopening = true;
    try {
      final opened = await _api.openThread(peer);
      if (!mounted || opened.id.isEmpty || opened.id == _threadId) {
        return false;
      }
      ChatAlerts.releaseThread(_threadId);
      ChatAlerts.holdThread(opened.id);
      setState(() {
        _threadId = opened.id;
        _forgetServerMessages();
      });
      return true;
    } catch (_) {
      return false;
    } finally {
      _reopening = false;
    }
  }

  bool _sameOutgoing(ChatMessage local, ChatMessage server) {
    if (_me.isEmpty || server.name != _me || local.name != _me) return false;
    if (local.pendingKind == 'voice') {
      return server.isVoice && server.voiceMs == local.voiceMs;
    }
    if (local.pendingKind == 'photo') {
      return server.isPhoto && server.text == local.text;
    }
    if (local.pendingKind == 'song') {
      return server.isSong && server.songName == local.songName;
    }
    return !server.isVoice &&
        !server.isPhoto &&
        !server.isSong &&
        server.text == local.text;
  }

  Future<void> _noteRead() async {
    if (_messages.isEmpty) return;
    var last = 0;
    for (final message in _messages) {
      if (message.id > last) last = message.id;
    }
    if (last <= 0 || last <= _readSent) return;
    await ChatReads.mark(_threadId, last);
    widget.onRead?.call(_threadId, last);
    try {
      await _api.markRead(_threadId, last);
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
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _recording || _threadId.isEmpty) return;
    final editing = _editingId;
    if (editing != null) {
      _clearComposer();
      try {
        final message = await _api.edit(_threadId, editing, text);
        if (!mounted) return;
        _ingest(message);
      } catch (error) {
        if (!mounted) return;
        setState(() => _error = chatErrorText(error));
      }
      return;
    }
    final reply = _replyId ?? 0;
    final replyName = _replyName;
    final replyText = _replyText;
    final local = _pending(
      text: text,
      reply: reply,
      replyName: replyName,
      replyText: replyText,
    );
    _clearComposer();
    _accept(local);
    try {
      final message = await _api.send(_threadId, text, reply: reply);
      if (!mounted) return;
      _replaceLocal(local.id, message);
    } catch (error) {
      if (mounted && _chatGone(error) && await _reopen()) {
        try {
          final message = await _api.send(_threadId, text);
          if (!mounted) return;
          _replaceLocal(local.id, message);
          return;
        } catch (_) {}
      }
      if (mounted && _messages.any((item) => item.id == local.id)) {
        _mark(local.id, 'failed');
      }
    }
  }

  Future<void> _storePhoto(ChatOutgoing outgoing, Uint8List bytes) async {
    final photoId = outgoing.message.photo;
    if (photoId.isEmpty) return;
    await ChatImageStore.save(photoId, bytes);
    await ChatImageStore.keep(_threadId, photoId);
    if (outgoing.held) {
      ChatLive.instance.sendBinary(
        encodeChatPhotoFrame(_threadId, photoId, bytes),
      );
    }
  }

  void _ingest(ChatMessage incoming) {
    if (!mounted || incoming.id <= 0) return;
    ChatMessage? local;
    for (final item in _messages) {
      if (item.id < 0 && _sameOutgoing(item, incoming)) {
        local = item;
        break;
      }
    }
    final message = local == null ? incoming : incoming.withQuoteFrom(local);
    final next = <ChatMessage>[];
    var placed = false;
    for (final item in _messages) {
      if (local != null && item.id == local.id) continue;
      if (item.id == message.id) {
        next.add(message.withQuoteFrom(item));
        placed = true;
        continue;
      }
      next.add(item);
    }
    if (!placed) next.add(message);
    final isNew = !placed;
    final mine = message.name == _me && _me.isNotEmpty;
    final stick = _stickToEnd || mine;
    setState(() {
      _messages = next;
      if (message.id > _after) _after = message.id;
      _error = null;
      if (isNew && !mine && !stick) _below += 1;
      if (stick) {
        _stickToEnd = true;
        _below = 0;
      }
    });
    if (isNew && stick) _jump(animate: true);
    if (isNew && !mine) unawaited(_noteRead());
    _remember();
  }

  Future<void> _attach() async {
    if (_recording || _threadId.isEmpty) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (Plat.isAndroid)
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Camera'),
                  minTileHeight: 48,
                  onTap: () => Navigator.pop(context, 'camera'),
                ),
              ListTile(
                leading: const Icon(Icons.photo_outlined),
                title: const Text('Gallery'),
                minTileHeight: 48,
                onTap: () => Navigator.pop(context, 'gallery'),
              ),
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('Document'),
                subtitle: const Text('A photo file can be sent'),
                minTileHeight: 48,
                onTap: () => Navigator.pop(context, 'document'),
              ),
              ListTile(
                leading: const Icon(Icons.music_note_outlined),
                title: const Text('Saved song'),
                subtitle: const Text('A song already saved in Social Save'),
                minTileHeight: 48,
                onTap: () => Navigator.pop(context, 'song'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || choice == null) return;
    if (choice == 'camera') {
      await _capturePhoto();
      return;
    }
    if (choice == 'document') {
      await _pickDocument();
      return;
    }
    if (choice == 'song') {
      await _pickSong();
      return;
    }
    await _pickPhoto();
  }

  Future<void> _capturePhoto() async {
    if (!Plat.isAndroid || _recording || _threadId.isEmpty) return;
    final status = await Permission.camera.request();
    if (!mounted) return;
    if (!status.isGranted) {
      setState(() => _error = 'Allow the camera to take a photo.');
      return;
    }
    String? path;
    try {
      path = await const MethodChannel(
        'socialsave/media',
      ).invokeMethod<String>('capturePhoto');
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = chatErrorText(error));
      return;
    }
    if (path == null || path.isEmpty || !mounted) return;
    try {
      final raw = await File(path).readAsBytes();
      final fitted = await fitChatImage(raw);
      if (!mounted) return;
      await _sendFittedPhoto(fitted);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is StateError
            ? error.message
            : chatErrorText(error),
      );
    }
  }

  Future<void> _pickSong() async {
    if (_recording || _threadId.isEmpty) return;
    List<({String title, String path, int ms, int size})> songs;
    try {
      final records = await ProviderScope.containerOf(
        context,
      ).read(downloadsRepositoryProvider).getAll();
      const allowed = {
        '.mp3',
        '.m4a',
        '.aac',
        '.ogg',
        '.wav',
        '.opus',
        '.flac',
      };
      songs = [];
      for (final record in records) {
        final path = record.localPath;
        if (path == null || path.isEmpty) continue;
        if (!allowed.contains(p.extension(path).toLowerCase())) continue;
        final file = File(path);
        if (!file.existsSync()) continue;
        final size = file.lengthSync();
        if (size <= 0 || size > 16 * 1024 * 1024) continue;
        final ms = (record.durationSeconds ?? 0) * 1000;
        if (ms > 20 * 60 * 1000) continue;
        final title = record.title.trim().isEmpty ? 'Song' : record.title.trim();
        songs.add((title: title, path: path, ms: ms, size: size));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = chatErrorText(error));
      return;
    }
    if (!mounted) return;
    if (songs.isEmpty) {
      setState(
        () => _error = 'No saved song under 16 MB is on this device.',
      );
      return;
    }
    final picked = await showModalBottomSheet<({String title, String path, int ms})>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final song in songs)
                ListTile(
                  leading: const Icon(Icons.music_note_rounded),
                  title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  minTileHeight: 48,
                  onTap: () => Navigator.pop(context, (
                    title: song.title,
                    path: song.path,
                    ms: song.ms,
                  )),
                ),
            ],
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    await _sendSongFile(picked.path, picked.title, picked.ms);
  }

  Future<void> _sendSongFile(String path, String title, int milliseconds) async {
    int? localId;
    try {
      final bytes = await File(path).readAsBytes();
      if (bytes.length > 16 * 1024 * 1024) {
        if (!mounted) return;
        setState(() => _error = 'That song is too large to send in chat.');
        return;
      }
      final reply = _replyId ?? 0;
      final replyName = _replyName;
      final replyText = _replyText;
      final local = _pending(
        text: title,
        kind: 'song',
        bytes: bytes,
        songName: title,
        songMs: milliseconds,
        reply: reply,
        replyName: replyName,
        replyText: replyText,
      );
      localId = local.id;
      _clearComposer();
      _accept(local);
      final message = await _api.sendSong(
        _threadId,
        bytes,
        name: title,
        milliseconds: milliseconds,
        reply: reply,
      );
      if (!mounted || !_messages.any((item) => item.id == local.id)) return;
      _replaceLocal(local.id, message);
    } catch (error) {
      if (!mounted) return;
      if (localId != null && _messages.any((item) => item.id == localId)) {
        _mark(localId, 'failed');
        return;
      }
      setState(() => _error = chatErrorText(error));
    }
  }

  Future<void> _pickDocument() async {
    if (_recording || _threadId.isEmpty) return;
    final picked = await openFile();
    if (picked == null || !mounted) return;
    final name = picked.name.toLowerCase();
    final photo =
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.png');
    if (!photo) {
      setState(() => _error = 'Only a photo can be sent from a file.');
      return;
    }
    try {
      final raw = await picked.readAsBytes();
      final fitted = await fitChatImage(raw);
      if (!mounted) return;
      await _sendFittedPhoto(fitted);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is StateError
            ? error.message
            : chatErrorText(error),
      );
    }
  }

  Future<void> _pickPhoto() async {
    if (_recording || _threadId.isEmpty) return;
    Uint8List? fitted;
    try {
      final picked = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Photos', extensions: ['jpg', 'jpeg', 'png']),
        ],
      );
      if (picked == null || !mounted) return;
      final raw = await picked.readAsBytes();
      fitted = await fitChatImage(raw);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is StateError
            ? error.message
            : chatErrorText(error),
      );
      return;
    }
    if (!mounted) return;
    await _sendFittedPhoto(fitted);
  }

  Future<void> _sendFittedPhoto(Uint8List fitted) async {
    int? localId;
    try {
      final caption = _text.text.trim();
      final reply = _replyId ?? 0;
      final replyName = _replyName;
      final replyText = _replyText;
      final stored = caption.isEmpty ? 'Photo' : caption;
      final local = _pending(
        text: stored,
        kind: 'photo',
        bytes: fitted,
        reply: reply,
        replyName: replyName,
        replyText: replyText,
      );
      localId = local.id;
      _clearComposer();
      _accept(local);
      final outgoing = await _api.sendPhoto(
        _threadId,
        fitted,
        caption: caption,
        reply: reply,
      );
      await _storePhoto(outgoing, fitted);
      if (!mounted || !_messages.any((item) => item.id == local.id)) return;
      _replaceLocal(local.id, outgoing.message);
    } catch (error) {
      if (!mounted) return;
      if (localId != null && _messages.any((item) => item.id == localId)) {
        _mark(localId, 'failed');
        return;
      }
      if (localId != null) return;
      setState(
        () =>
            _error = error is StateError ? error.message : chatErrorText(error),
      );
    }
  }

  Future<void> _retry(ChatMessage message) async {
    if (message.id >= 0 || message.status == 'sending') return;
    _mark(message.id, 'sending');
    try {
      final ChatMessage sent;
      if (message.pendingKind == 'voice' && message.localBytes != null) {
        sent = await _api.sendVoice(
          _threadId,
          message.localBytes!,
          message.voiceMs,
          reply: message.reply,
        );
      } else if (message.pendingKind == 'song' && message.localBytes != null) {
        sent = await _api.sendSong(
          _threadId,
          message.localBytes!,
          name: message.songName.isEmpty ? message.text : message.songName,
          milliseconds: message.songMs,
          reply: message.reply,
        );
      } else if (message.pendingKind == 'photo' && message.localBytes != null) {
        final caption = message.text == 'Photo' ? '' : message.text;
        final outgoing = await _api.sendPhoto(
          _threadId,
          message.localBytes!,
          caption: caption,
          reply: message.reply,
        );
        await _storePhoto(outgoing, message.localBytes!);
        sent = outgoing.message;
      } else {
        sent = await _api.send(
          _threadId,
          message.text,
          reply: message.reply,
        );
      }
      if (!mounted || !_messages.any((item) => item.id == message.id)) return;
      _replaceLocal(message.id, sent);
    } catch (error) {
      // A lost chat gets a fresh id, so the next tap on retry goes through.
      if (mounted && _chatGone(error)) await _reopen();
      if (mounted && _messages.any((item) => item.id == message.id)) {
        _mark(message.id, 'failed');
      }
    }
  }

  ChatMessage _pending({
    required String text,
    String kind = '',
    Uint8List? bytes,
    int voiceMs = 0,
    String songName = '',
    int songMs = 0,
    int reply = 0,
    String replyName = '',
    String replyText = '',
  }) {
    _localSeq -= 1;
    return ChatMessage(
      id: _localSeq,
      from: _me,
      name: _me,
      text: text,
      links: const [],
      at: DateTime.now(),
      status: 'sending',
      voiceMs: voiceMs,
      songName: songName,
      songMs: songMs,
      reply: reply,
      replyName: replyName,
      replyText: replyText,
      localBytes: bytes,
      pendingKind: kind,
    );
  }

  void _clearComposer() {
    _text.clear();
    _replyId = null;
    _replyName = '';
    _replyText = '';
    _editingId = null;
    _typingIdle?.cancel();
    ChatLive.instance.typing(_threadId, on: false);
    unawaited(ChatDrafts.write(_threadId, ''));
  }

  void _mark(int id, String status) {
    if (!mounted) return;
    setState(() {
      _messages = [
        for (final item in _messages)
          if (item.id == id) item.copyWith(status: status) else item,
      ];
    });
    _remember();
  }

  void _replaceLocal(int localId, ChatMessage message) {
    if (!mounted) return;
    ChatMessage? local;
    for (final item in _messages) {
      if (item.id == localId) local = item;
    }
    final merged = local == null ? message : message.withQuoteFrom(local);
    final bytes = local?.localBytes;
    if (merged.voice.isNotEmpty && bytes != null && bytes.isNotEmpty) {
      unawaited(ChatVoiceFiles.save(merged.voice, merged.voiceType, bytes));
    }
    if (merged.song.isNotEmpty && bytes != null && bytes.isNotEmpty) {
      unawaited(ChatSongFiles.save(merged.song, merged.songType, bytes));
    }
    final next = <ChatMessage>[];
    for (final item in _messages) {
      if (item.id == merged.id) continue;
      next.add(item.id == localId ? merged : item);
    }
    if (!next.any((item) => item.id == merged.id)) next.add(merged);
    setState(() {
      _messages = next;
      if (merged.id > _after) _after = merged.id;
      _error = null;
      _stickToEnd = true;
      _below = 0;
    });
    _jump(animate: true);
    unawaited(_noteRead());
    _remember();
  }

  void _replyTo(ChatMessage message) {
    if (message.id <= 0) return;
    unawaited(HapticFeedback.selectionClick());
    setState(() {
      _replyId = message.id;
      _replyName = message.name;
      _replyText = message.isSong
          ? (message.songName.trim().isEmpty ? 'Song' : message.songName.trim())
          : chatQuoteLabel(
              message.text,
              voice: message.isVoice,
              photo: message.isPhoto,
            );
      _editingId = null;
    });
    _focus.requestFocus();
  }

  void _accept(ChatMessage message) {
    setState(() {
      if (!_messages.any((item) => item.id == message.id)) {
        _messages = [..._messages, message];
      }
      if (message.id > _after) _after = message.id;
      _stickToEnd = true;
      _below = 0;
      _error = null;
    });
    _jump(animate: true);
    unawaited(_noteRead());
    _remember();
  }

  Future<void> _startVoice() async {
    if (_recording || _threadId.isEmpty || Plat.isWeb) return;
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
    ChatLive.instance.typing(_threadId, on: false);
    ChatLive.instance.recording(_threadId, on: true);
  }

  Future<void> _finishVoice({required bool send}) async {
    if (_finishingVoice) return;
    _finishingVoice = true;
    ChatLive.instance.recording(_threadId, on: false);
    var voiceLocal = 0;
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
      final ms = taken.ms > 60000 ? 60000 : taken.ms;
      final reply = _replyId ?? 0;
      final replyName = _replyName;
      final replyText = _replyText;
      final local = _pending(
        text: 'Voice message',
        kind: 'voice',
        bytes: bytes,
        voiceMs: ms,
        reply: reply,
        replyName: replyName,
        replyText: replyText,
      );
      _replyId = null;
      _replyName = '';
      _replyText = '';
      voiceLocal = local.id;
      _accept(local);
      final message = await _api.sendVoice(
        _threadId,
        bytes,
        ms,
        reply: reply,
      );
      if (!mounted || !_messages.any((item) => item.id == voiceLocal)) return;
      _replaceLocal(voiceLocal, message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _recording = false);
      if (voiceLocal < 0 && _messages.any((item) => item.id == voiceLocal)) {
        _mark(voiceLocal, 'failed');
        return;
      }
      if (voiceLocal < 0) return;
      setState(() => _error = chatErrorText(error));
    } finally {
      _finishingVoice = false;
    }
  }

  void _openLink(String url) {
    context.push('/preview', extra: url);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_enterSends || event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    unawaited(_send());
    return KeyEventResult.handled;
  }

  void _toggleSelect(ChatMessage message) {
    setState(() {
      if (_selected.contains(message.id)) {
        _selected.remove(message.id);
      } else {
        _selected.add(message.id);
      }
    });
  }

  List<ChatMessage> get _picked => [
    for (final message in _messages)
      if (_selected.contains(message.id)) message,
  ];

  Widget _selectionBar() {
    final picked = _picked;
    final one = picked.length == 1 ? picked.first : null;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              '${_selected.length}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
          if (one != null && one.id > 0)
            for (final emoji in const ['👍', '❤️', '😂', '😮', '😢', '🙏'])
              IconButton(
                tooltip: emoji,
                onPressed: () => unawaited(_react(one, emoji)),
                icon: Text(emoji, style: const TextStyle(fontSize: 20)),
              ),
          if (one != null && one.id > 0)
            IconButton(
              tooltip: 'Reply',
              onPressed: () {
                final message = one;
                setState(_selected.clear);
                _replyTo(message);
              },
              icon: const Icon(Icons.reply_rounded),
            ),
          if (picked.any((message) => message.text.trim().isNotEmpty))
            IconButton(
              tooltip: 'Copy',
              onPressed: () => unawaited(_copyPicked()),
              icon: const Icon(Icons.copy_rounded),
            ),
          if (one != null && _canEdit(one))
            IconButton(
              tooltip: 'Edit',
              onPressed: () => _beginEdit(one),
              icon: const Icon(Icons.edit_outlined),
            ),
          if (one != null && one.id > 0)
            IconButton(
              tooltip: _pinned.contains(one.id) ? 'Unpin' : 'Pin',
              onPressed: () => unawaited(_togglePin(one)),
              icon: Icon(
                _pinned.contains(one.id)
                    ? Icons.push_pin
                    : Icons.push_pin_outlined,
              ),
            ),
          if (one != null && one.id > 0 && one.name == _me && _me.isNotEmpty)
            IconButton(
              tooltip: 'Info',
              onPressed: () => unawaited(_showInfo(one)),
              icon: const Icon(Icons.info_outline_rounded),
            ),
          if (one != null &&
              one.text.trim().isNotEmpty &&
              !one.isPhoto &&
              !one.isVoice &&
              !one.isSong)
            IconButton(
              tooltip: 'Forward',
              onPressed: () => unawaited(_forward(one)),
              icon: const Icon(Icons.forward_rounded),
            ),
          IconButton(
            tooltip: 'Delete',
            onPressed: () => unawaited(_deletePicked()),
            icon: const Icon(Icons.delete_outline_rounded),
          ),
          if (one != null && one.id > 0 && one.name == _me && _me.isNotEmpty)
            IconButton(
              tooltip: 'Unsend',
              onPressed: () => unawaited(_unsendOne(one)),
              icon: const Icon(Icons.undo_rounded),
            ),
          if (one != null && one.links.isNotEmpty)
            IconButton(
              tooltip: 'Save link',
              onPressed: () {
                final link = one.links.first;
                setState(_selected.clear);
                _openLink(link);
              },
              icon: const Icon(Icons.link_rounded),
            ),
        ],
      ),
    );
  }

  bool _canEdit(ChatMessage message) {
    if (message.id <= 0 || message.name != _me || _me.isEmpty) return false;
    if (message.isVoice || message.isSong || message.isPhoto) return false;
    if (message.text.trim().isEmpty) return false;
    return DateTime.now().difference(message.at) < const Duration(hours: 24);
  }

  Future<void> _react(ChatMessage message, String emoji) async {
    setState(_selected.clear);
    try {
      final updated = await _api.react(_threadId, message.id, emoji);
      if (!mounted) return;
      _ingest(updated);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = chatErrorText(error));
    }
  }

  void _beginEdit(ChatMessage message) {
    setState(() {
      _selected.clear();
      _editingId = message.id;
      _replyId = null;
      _replyName = '';
      _replyText = '';
      _text.text = message.text;
      _text.selection = TextSelection.collapsed(offset: _text.text.length);
    });
    _focus.requestFocus();
  }

  Future<void> _togglePin(ChatMessage message) async {
    setState(_selected.clear);
    try {
      final pinned = await _api.pin(_threadId, message.id);
      if (!mounted) return;
      setState(() => _pinned = pinned);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = chatErrorText(error));
    }
  }

  Future<void> _showInfo(ChatMessage message) async {
    setState(_selected.clear);
    try {
      final info = await _api.info(_threadId, message.id);
      if (!mounted) return;
      String line(String label, DateTime? at) {
        if (at == null) return '';
        final local = at.toLocal();
        final clock = TimeOfDay.fromDateTime(local).format(context);
        return '$label · ${chatDayLabel(at, DateTime.now())} $clock';
      }

      final lines = [
        line('Sent', info.at),
        if (info.editedAt != null) line('Edited', info.editedAt),
        line('Delivered', info.deliveredAt),
        line('Read', info.readAt),
      ].where((item) => item.isNotEmpty).join('\n');
      await showDialog<void>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('Message info'),
            content: Text(lines.isEmpty ? 'Sent' : lines),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          );
        },
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = chatErrorText(error));
    }
  }

  Future<void> _copyPicked() async {
    final text = [
      for (final message in _picked)
        if (message.text.trim().isNotEmpty) message.text.trim(),
    ].join('\n');
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(_selected.clear);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Message copied')));
  }

  Future<void> _deletePicked() async {
    final yes = await _confirm(
      'Delete message',
      'This removes it from this phone. The other person still has it.',
      'Delete',
    );
    if (!yes || !mounted) return;
    final ids = _picked.map((message) => message.id).toList();
    for (final id in ids) {
      _drop(id);
    }
    setState(_selected.clear);
  }

  Future<void> _unsendOne(ChatMessage message) async {
    final yes = await _confirm(
      'Unsend message',
      'This removes it for both of you.',
      'Unsend',
    );
    if (!yes || !mounted) return;
    try {
      await _api.unsend(_threadId, message.id);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = chatErrorText(error));
      return;
    }
    _drop(message.id);
    if (mounted) setState(_selected.clear);
  }

  Future<void> _forward(ChatMessage message) async {
    final text = message.text.trim();
    if (text.isEmpty || message.isPhoto || message.isVoice) return;
    final List<ChatThreadSummary> threads;
    try {
      threads = await _api.threads();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = chatErrorText(error));
      return;
    }
    if (!mounted) return;
    final others = [
      for (final item in threads)
        if (item.id != _threadId) item,
    ];
    if (others.isEmpty) {
      setState(() => _error = 'There is no other chat to forward to.');
      return;
    }
    final target = await showModalBottomSheet<ChatThreadSummary>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final item in others)
                ListTile(
                  title: Text(item.label),
                  minTileHeight: 48,
                  onTap: () => Navigator.pop(context, item),
                ),
            ],
          ),
        );
      },
    );
    if (target == null || !mounted) return;
    try {
      await _api.send(target.id, text);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = chatErrorText(error));
      return;
    }
    if (!mounted) return;
    setState(_selected.clear);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Forwarded to ${target.label}')));
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        );
      },
    );
    return yes == true;
  }

  void _drop(int id) {
    if (!mounted) return;
    final next = [for (final item in _messages) if (item.id != id) item];
    if (next.length != _messages.length) {
      setState(() {
        _messages = next;
        _selected.remove(id);
        _pinned = [for (final pinned in _pinned) if (pinned != id) pinned];
      });
    }
    if (_me.isEmpty || _threadId.isEmpty) return;
    unawaited(
      ChatHistory.hide(username: _me, threadId: _threadId, ids: [id]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final handle = widget.username.replaceFirst(RegExp(r'^@'), '').trim();
    final title = _seenName.trim().isNotEmpty
        ? _seenName.trim()
        : (handle.isEmpty ? (_isGroup ? 'Group' : 'Chat') : handle);
    final face = _isGroup ? title : (handle.isEmpty ? '?' : handle);
    final dark = scheme.brightness == Brightness.dark;
    final canvas = ChatUiTokens.canvas(dark);
    final selecting = _selected.isNotEmpty;
    final recording = ChatLive.isRecording(_threadId);
    final peerTyping = !recording && ChatLive.isTyping(_threadId);
    final presence = chatPresenceLabel(
      _peerSeen,
      _peerOnline,
      DateTime.now(),
      _peerSeen == null
          ? ''
          : TimeOfDay.fromDateTime(_peerSeen!.toLocal()).format(context),
    );
    final groupLine = _isGroup
        ? [
            if (_members.isNotEmpty)
              _members.length == 1 ? '1 person' : '${_members.length} people',
            if (_peerOnline) 'online',
          ].join(' · ')
        : presence;
    final subtitle = recording
        ? 'recording audio…'
        : peerTyping
        ? 'typing…'
        : groupLine;
    final body = Column(
      children: [
        AppBar(
          toolbarHeight: 64,
          elevation: 0,
          scrolledUnderElevation: 0,
          backgroundColor: scheme.surface,
          surfaceTintColor: Colors.transparent,
          automaticallyImplyLeading: !selecting && !widget.embedded,
          titleSpacing: widget.embedded ? 16 : 0,
          leading: selecting
              ? IconButton(
                  tooltip: 'Clear',
                  onPressed: () => setState(_selected.clear),
                  icon: const Icon(Icons.close_rounded),
                )
              : null,
          actions: [
            if (!selecting)
              IconButton(
                tooltip: _searching ? 'Close search' : 'Search',
                onPressed: () => setState(() {
                  _searching = !_searching;
                  if (!_searching) _search.clear();
                }),
                icon: Icon(
                  _searching ? Icons.close_rounded : Icons.search_rounded,
                ),
              ),
          ],
          title: selecting
              ? _selectionBar()
              : _searching
              ? TextField(
                  controller: _search,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Search this chat',
                    border: InputBorder.none,
                  ),
                  onChanged: (_) => setState(() {}),
                )
              : InkWell(
            onTap: () => unawaited(_openProfile(face, handle, title)),
            child: Row(
              children: [
                ChatFace(
                  name: face,
                  size: 36,
                  photoRev: _peerPhoto,
                  online: _peerOnline,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (subtitle.isNotEmpty)
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            fontStyle: recording || peerTyping
                                ? FontStyle.italic
                                : FontStyle.normal,
                            color: recording || peerTyping || _peerOnline
                                ? const Color(0xFF25D366)
                                : scheme.onSurfaceVariant,
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
              child: Text(
                _error!,
                style: TextStyle(color: scheme.onErrorContainer, height: 1.35),
              ),
            ),
          ),
        Expanded(
          child: ColoredBox(
            color: canvas,
            child: Stack(
              children: [
                Positioned.fill(
                  child: ChatWallpaper(
                    dark: scheme.brightness == Brightness.dark,
                  ),
                ),
                if (_pinned.isNotEmpty && !_searching)
                  Positioned(
                    top: 8,
                    left: 12,
                    right: 12,
                    child: Material(
                      color: scheme.brightness == Brightness.dark
                          ? const Color(0xFF1F2C34)
                          : Colors.white,
                      elevation: 1,
                      borderRadius: BorderRadius.circular(12),
                      child: ListTile(
                        dense: true,
                        minTileHeight: 48,
                        leading: const Icon(
                          Icons.push_pin_rounded,
                          color: Color(0xFF25D366),
                        ),
                        title: Text(
                          _pinnedPreview(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: _jumpPinned,
                      ),
                    ),
                  ),
                if (_starting)
                  const Center(child: CircularProgressIndicator())
                else if (_shown.isEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        _messages.isEmpty
                            ? 'No messages yet. Say hello, or paste a public link. Tap a link to save it.'
                            : 'No messages match that search.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ),
                  )
                else
                  Builder(
                    builder: (context) {
                      final rows = _rows();
                      return ListView.builder(
                        controller: _scroll,
                        padding: EdgeInsets.fromLTRB(
                          12,
                          _pinned.isNotEmpty && !_searching ? 72 : 12,
                          12,
                          12,
                        ),
                        itemCount: rows.length,
                        itemBuilder: (context, index) {
                          final row = rows[index];
                          if (row.banner != null) {
                            return ChatDayPill(label: row.banner!);
                          }
                          if (row.day != null) {
                            return ChatDayPill(label: row.day!);
                          }
                          final message = row.message!;
                          final mine = message.name == _me && _me.isNotEmpty;
                          final previous = index > 0
                              ? rows[index - 1].message
                              : null;
                          final following = index + 1 < rows.length
                              ? rows[index + 1].message
                              : null;
                          final tail =
                              following == null ||
                              following.name != message.name ||
                              following.at.difference(message.at).inMinutes.abs() >=
                                  5;
                          final tight =
                              previous != null &&
                              previous.name == message.name &&
                              message.at.difference(previous.at).inMinutes.abs() <
                                  5;
                          final picked = _selected.contains(message.id);
                          Widget bubble = ChatBubble(
                            key: _keyFor(message.id),
                            message: message,
                            threadId: _threadId,
                            mine: mine,
                            tail: tail,
                            tight: tight,
                            api: _api,
                            tick: chatTick(
                              mine: mine,
                              id: message.id,
                              peerDelivered: _peerDelivered,
                              peerRead: _peerRead,
                              status: message.status,
                            ),
                            onLink: _openLink,
                            onQuote: _scrollToMessage,
                            onRetry: message.status == 'failed'
                                ? () => unawaited(_retry(message))
                                : null,
                            onLongPress: (_) => _toggleSelect(message),
                          );
                          if (picked) {
                            bubble = ColoredBox(
                              color: ChatUiTokens.brand.withValues(alpha: 0.18),
                              child: SizedBox(
                                width: double.infinity,
                                child: bubble,
                              ),
                            );
                          }
                          if (message.id <= 0) {
                            if (!selecting) return bubble;
                            return GestureDetector(
                              onTap: () => _toggleSelect(message),
                              behavior: HitTestBehavior.opaque,
                              child: AbsorbPointer(
                                child: SizedBox(
                                  width: double.infinity,
                                  child: bubble,
                                ),
                              ),
                            );
                          }
                          final replyRow = Dismissible(
                            key: ValueKey('reply-${message.id}'),
                            direction: DismissDirection.startToEnd,
                            dismissThresholds: const {
                              DismissDirection.startToEnd: 0.2,
                            },
                            confirmDismiss: (_) {
                              final target = message;
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) _replyTo(target);
                              });
                              return Future<bool>.value(false);
                            },
                            background: const Align(
                              alignment: Alignment.centerLeft,
                              child: Padding(
                                padding: EdgeInsets.only(left: 8),
                                child: Icon(
                                  Icons.reply_rounded,
                                  color: Color(0xFF25D366),
                                ),
                              ),
                            ),
                            child: SizedBox(
                              width: double.infinity,
                              child: bubble,
                            ),
                          );
                          if (!selecting) return replyRow;
                          return GestureDetector(
                            onTap: () => _toggleSelect(message),
                            behavior: HitTestBehavior.opaque,
                            child: AbsorbPointer(child: replyRow),
                          );
                        },
                      );
                    },
                  ),
                if (_below > 0)
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: ChatDownChip(
                      count: _below,
                      onPressed: () {
                        setState(() {
                          _stickToEnd = true;
                          _below = 0;
                        });
                        _jump(animate: true);
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface,
            border: Border(
              top: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.55),
              ),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (recording)
                    const Padding(
                      padding: EdgeInsets.only(left: 14, bottom: 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'recording audio…',
                          style: TextStyle(
                            color: Color(0xFF25D366),
                            fontStyle: FontStyle.italic,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    )
                  else if (peerTyping)
                    const Padding(
                      padding: EdgeInsets.only(left: 14, bottom: 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'typing…',
                          style: TextStyle(
                            color: Color(0xFF25D366),
                            fontStyle: FontStyle.italic,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  if (_editingId != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                      decoration: BoxDecoration(
                        color: scheme.brightness == Brightness.dark
                            ? const Color(0xFF1F2C34)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: const Border(
                          left: BorderSide(color: Color(0xFF25D366), width: 3),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Editing',
                              style: TextStyle(
                                color: Color(0xFF25D366),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Cancel edit',
                            onPressed: () => setState(() {
                              _editingId = null;
                              _text.clear();
                            }),
                            icon: const Icon(Icons.close_rounded, size: 20),
                          ),
                        ],
                      ),
                    ),
                  if (_blocked && !_isGroup)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text('You blocked this person.'),
                          ),
                          TextButton(
                            onPressed: () => unawaited(_setBlocked(false)),
                            child: const Text('Unblock'),
                          ),
                        ],
                      ),
                    )
                  else ...[
                  if (_replyText.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                      decoration: BoxDecoration(
                        color: scheme.brightness == Brightness.dark
                            ? const Color(0xFF1F2C34)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: const Border(
                          left: BorderSide(color: Color(0xFF25D366), width: 3),
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _replyName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFF25D366),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                  ),
                                ),
                                Text(
                                  _replyText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Cancel reply',
                            onPressed: () => setState(() {
                              _replyId = null;
                              _replyName = '';
                              _replyText = '';
                            }),
                            icon: const Icon(Icons.close_rounded, size: 20),
                          ),
                        ],
                      ),
                    ),
                  if (_recording)
                    ChatRecordingBar(
                      view: _recorder.view,
                      onDelete: () => unawaited(_finishVoice(send: false)),
                      onSend: () => unawaited(_finishVoice(send: true)),
                      onPause: () => unawaited(_recorder.togglePause()),
                    )
                  else
                    ChatComposer(
                      controller: _text,
                      focusNode: _focus,
                      enterSends: _enterSends,
                      onKey: _onKey,
                      onChanged: _onTyped,
                      onSend: () => unawaited(_send()),
                      onMic: () => unawaited(_startVoice()),
                      onAttach: () => unawaited(_attach()),
                      showMic: !Plat.isWeb,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(body: body);
  }

  List<ChatMessage> get _shown {
    final query = _search.text.trim().toLowerCase();
    if (!_searching || query.isEmpty) return _messages;
    return [
      for (final message in _messages)
        if (message.text.toLowerCase().contains(query) ||
            message.replyText.toLowerCase().contains(query) ||
            message.songName.toLowerCase().contains(query))
          message,
    ];
  }

  String _pinnedPreview() {
    for (final id in _pinned.reversed) {
      for (final message in _messages) {
        if (message.id != id) continue;
        if (message.isSong && message.songName.trim().isNotEmpty) {
          return message.songName.trim();
        }
        final text = message.text.trim();
        if (text.isNotEmpty) return text;
      }
    }
    return _pinned.length == 1 ? 'Pinned message' : '${_pinned.length} pinned';
  }

  void _jumpPinned() {
    if (_pinned.isEmpty) return;
    final id = _pinned[_pinCursor % _pinned.length];
    setState(() => _pinCursor++);
    _scrollToMessage(id);
  }

  Future<void> _setBlocked(bool on) async {
    final handle = widget.username.replaceFirst(RegExp(r'^@'), '').trim();
    if (handle.isEmpty) return;
    try {
      final blocked = await _api.block(handle, on: on);
      if (!mounted) return;
      setState(() => _blocked = blocked);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = chatErrorText(error));
    }
  }

  Future<void> _openProfile(String face, String handle, String title) async {
    if (_isGroup) {
      try {
        final group = await _api.group(_threadId);
        if (!mounted) return;
        await showChatGroup(
          context,
          name: group.name,
          code: group.code,
          members: group.members,
          onAdd: (value) async {
            final group = await _api.addMember(_threadId, value);
            if (mounted) setState(() => _members = group.members);
            return group.members;
          },
          onRename: (value) async {
            final saved = await _api.renameGroup(_threadId, value);
            if (mounted && saved.isNotEmpty) {
              setState(() => _seenName = saved);
              widget.onSeenName?.call(_threadId, saved);
            }
            return saved;
          },
          onLeave: () async {
            await _api.leaveGroup(_threadId);
            if (!mounted) return;
            widget.onLeft?.call(_threadId);
            if (!widget.embedded && context.canPop()) context.pop();
          },
        );
      } catch (error) {
        if (!mounted) return;
        setState(() => _error = chatErrorText(error));
      }
      return;
    }
    await showChatProfile(
      context,
      username: face == '?' ? title : handle,
      seenName: _seenName,
      photoRev: _peerPhoto,
      lastSeen: _peerSeen,
      online: _peerOnline,
      blocked: _blocked,
      onBlock: handle.isEmpty
          ? null
          : (on) async {
              final blocked = await _api.block(handle, on: on);
              if (mounted) setState(() => _blocked = blocked);
              return blocked;
            },
      onSeenName: handle.isEmpty
          ? null
          : (value) async {
              final saved = await _api.setSeenName(handle, value);
              if (mounted) setState(() => _seenName = saved);
              widget.onSeenName?.call(_threadId, saved);
              return saved;
            },
    );
  }

  List<_Row> _rows() {
    final rows = <_Row>[];
    DateTime? previous;
    final now = DateTime.now();
    final shown = _shown;
    var markedNew = false;
    var newCount = 0;
    for (final message in shown) {
      if (message.name != _me && message.id > _seenAtOpen) newCount++;
    }
    for (final message in shown) {
      final local = message.at.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      if (previous == null || day != previous) {
        rows.add(_Row.day(chatDayLabel(message.at, now)));
        previous = day;
      }
      final isNew =
          _bannerAfter >= 0 && message.name != _me && message.id > _bannerAfter;
      if (isNew && !markedNew) {
        markedNew = true;
        final label = newCount == 1
            ? '1 unread message'
            : '$newCount unread messages';
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
  const ChatFace({
    super.key,
    required this.name,
    this.photoRev = 0,
    this.size = 48,
    this.online = false,
  });

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
    if (oldWidget.photoRev != widget.photoRev ||
        oldWidget.name != widget.name) {
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
    return ChatAvatar(
      name: widget.name,
      size: widget.size,
      bytes: _bytes,
      online: widget.online,
    );
  }
}

class ChatAvatar extends StatelessWidget {
  const ChatAvatar({
    super.key,
    required this.name,
    this.size = 48,
    this.bytes,
    this.online = false,
  });

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
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: size * 0.38,
              ),
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
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.message,
    required this.threadId,
    required this.mine,
    required this.api,
    required this.tick,
    required this.onLink,
    required this.onLongPress,
    this.tail = true,
    this.tight = false,
    this.onQuote,
    this.onRetry,
  });

  final ChatMessage message;
  final String threadId;
  final bool mine;
  final bool tail;
  final bool tight;
  final ChatApi api;
  final String tick;
  final ValueChanged<String> onLink;
  final ValueChanged<int>? onQuote;
  final ValueChanged<LongPressStartDetails>? onLongPress;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final dark = ChatUiTokens.dark(context);
    final bg = mine ? ChatUiTokens.outgoing(dark) : ChatUiTokens.incoming(dark);
    final fg = ChatUiTokens.text(dark);
    final link = ChatUiTokens.link(dark);
    final time = TimeOfDay.fromDateTime(message.at.toLocal()).format(context);
    final tickColor = chatTickColor(tick, dark: dark);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cap = constraints.maxWidth * ChatUiTokens.bubbleMax;
          final max = cap > 420 ? 420.0 : cap;
          final inner = max - 16;
          final voiceWidth = inner > 328 ? 328.0 : (inner < 0 ? 0.0 : inner);
          final cardWidth = inner > 260 ? 260.0 : (inner < 0 ? 0.0 : inner);
          final quote = message.replyText.isEmpty
              ? null
              : _Quote(
                  name: message.replyName,
                  text: message.replyText,
                  dark: dark,
                  onTap: message.reply > 0 && onQuote != null
                      ? () => onQuote!(message.reply)
                      : null,
                );
          final timeColor = ChatUiTokens.time(dark);
          final stamp = _stamp(
            time,
            timeColor,
            tick,
            tickColor: tickColor,
            onRetry: onRetry,
            edited: message.isEdited,
          );
          final caption = message.text.trim();
          final reserve = message.isEdited ? (mine ? 118.0 : 98.0) : (mine ? 78.0 : 58.0);
          final barePhoto =
              message.isPhoto && (caption.isEmpty || caption == 'Photo');
          final Widget body;
          if (message.isVoice) {
            body = SizedBox(
              width: voiceWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ?quote,
                  ChatVoiceBubble(
                    message: message,
                    api: api,
                    mine: mine,
                    dark: dark,
                  ),
                  stamp,
                ],
              ),
            );
          } else if (message.isPhoto) {
            final overlayTick = tick == 'read'
                ? const Color(0xFF53BDEB)
                : Colors.white;
            body = SizedBox(
              width: cardWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ?quote,
                  Stack(
                    children: [
                      _ChatPicture(message: message, threadId: threadId),
                      if (barePhoto)
                        Positioned(
                          right: 4,
                          bottom: 4,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0x8A000000),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(6, 1, 4, 1),
                              child: _stamp(
                                time,
                                Colors.white,
                                tick,
                                tickColor: overlayTick,
                                onRetry: onRetry,
                                onDark: true,
                                edited: message.isEdited,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (!barePhoto) ...[
                    const SizedBox(height: 4),
                    _TimedLine(
                      text: _LinkText(
                        text: message.text,
                        links: message.links,
                        color: fg,
                        linkColor: link,
                        onLink: onLink,
                        reserve: reserve,
                      ),
                      stamp: stamp,
                    ),
                  ],
                ],
              ),
            );
          } else if (message.isSong) {
            body = SizedBox(
              width: voiceWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ?quote,
                  ChatSongBubble(
                    message: message,
                    api: api,
                    mine: mine,
                    dark: dark,
                  ),
                  stamp,
                ],
              ),
            );
          } else if (message.links.isNotEmpty) {
            body = SizedBox(
              width: cardWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ?quote,
                  ChatLinkCard(url: message.links.first, onOpen: onLink),
                  _TimedLine(
                    text: _LinkText(
                      text: message.text,
                      links: message.links,
                      color: fg,
                      linkColor: link,
                      onLink: onLink,
                      reserve: reserve,
                    ),
                    stamp: stamp,
                  ),
                ],
              ),
            );
          } else {
            body = IntrinsicWidth(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ?quote,
                  _TimedLine(
                    text: _LinkText(
                      text: message.text,
                      links: message.links,
                      color: fg,
                      linkColor: link,
                      onLink: onLink,
                      reserve: reserve,
                    ),
                    stamp: stamp,
                  ),
                ],
              ),
            );
          }
          final radius = BorderRadius.only(
            topLeft: Radius.circular(tight && !mine ? 6 : 8),
            topRight: Radius.circular(tight && mine ? 6 : 8),
            bottomLeft: Radius.circular(!tail || mine ? 8 : 0),
            bottomRight: Radius.circular(!tail || !mine ? 8 : 0),
          );
          return GestureDetector(
            onLongPressStart: onLongPress,
            child: Padding(
              padding: EdgeInsets.only(
                top: tight ? 1 : 7,
                bottom: tail ? 2 : 1,
                left: mine ? 0 : 8,
                right: mine ? 8 : 0,
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    constraints: BoxConstraints(maxWidth: max),
                    padding: EdgeInsets.fromLTRB(
                      barePhoto ? 3 : 8,
                      barePhoto ? 3 : 6,
                      barePhoto ? 3 : 7,
                      barePhoto ? 3 : 4,
                    ),
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: radius,
                      boxShadow: dark
                          ? null
                          : const [
                              BoxShadow(
                                color: Color(0x14000000),
                                blurRadius: 0.5,
                                offset: Offset(0, 1),
                              ),
                            ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        body,
                        if (message.reactions.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Wrap(
                              spacing: 4,
                              runSpacing: 2,
                              children: [
                                for (final chip in _reactionChips(
                                  message.reactions,
                                ))
                                  chip,
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (tail)
                    Positioned(
                      right: mine ? -7 : null,
                      left: mine ? null : -7,
                      bottom: 0,
                      child: CustomPaint(
                        size: const Size(10, 12),
                        painter: _BubbleTail(color: bg, mine: mine),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _TimedLine extends StatelessWidget {
  const _TimedLine({required this.text, required this.stamp});

  final Widget text;
  final Widget stamp;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        text,
        Positioned(right: 0, bottom: 0, child: stamp),
      ],
    );
  }
}

class _BubbleTail extends CustomPainter {
  const _BubbleTail({required this.color, required this.mine});

  final Color color;
  final bool mine;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    final w = size.width;
    final h = size.height;
    if (mine) {
      path
        ..moveTo(0, 0)
        ..quadraticBezierTo(w * 0.9, h * 0.28, w, h)
        ..lineTo(0, h);
    } else {
      path
        ..moveTo(w, 0)
        ..quadraticBezierTo(w * 0.1, h * 0.28, 0, h)
        ..lineTo(w, h);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_BubbleTail old) => old.color != color || old.mine != mine;
}

List<Widget> _reactionChips(List<ChatReaction> reactions) {
  final counts = <String, int>{};
  for (final item in reactions) {
    if (item.emoji.isEmpty) continue;
    counts[item.emoji] = (counts[item.emoji] ?? 0) + 1;
  }
  return [
    for (final entry in counts.entries)
      DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0x14000000),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: Text(
            entry.value > 1 ? '${entry.key} ${entry.value}' : entry.key,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ),
  ];
}

Widget _stamp(
  String time,
  Color timeColor,
  String tick, {
  Color? tickColor,
  VoidCallback? onRetry,
  bool onDark = false,
  bool edited = false,
}) {
  final IconData? icon;
  var iconColor = tickColor ?? timeColor;
  var size = 15.0;
  if (tick == 'failed') {
    icon = Icons.error_outline;
    iconColor = const Color(0xFFEF5350);
  } else if (tick == 'sending') {
    icon = Icons.schedule_rounded;
    size = 13;
  } else if (tick == 'sent') {
    icon = Icons.done_rounded;
  } else if (tick == 'delivered' || tick == 'read') {
    icon = Icons.done_all_rounded;
  } else {
    icon = null;
  }
  final mark = icon == null
      ? const SizedBox.shrink()
      : tick == 'failed' && onRetry != null
      ? IconButton(
          tooltip: 'Tap to retry',
          onPressed: onRetry,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
          icon: Icon(icon, size: size, color: iconColor),
        )
      : Icon(icon, size: size, color: iconColor);
  return Align(
    alignment: Alignment.centerRight,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (edited) ...[
          Text(
            'edited',
            style: TextStyle(
              fontSize: 11,
              height: 1.1,
              color: timeColor,
              fontStyle: FontStyle.italic,
            ),
          ),
          const SizedBox(width: 3),
        ],
        Text(
          time,
          style: TextStyle(
            fontSize: 11,
            height: 1.1,
            color: timeColor,
            fontWeight: onDark ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        if (icon != null) ...[const SizedBox(width: 2), mark],
      ],
    ),
  );
}

class _Quote extends StatelessWidget {
  const _Quote({
    required this.name,
    required this.text,
    required this.dark,
    this.onTap,
  });

  final String name;
  final String text;
  final bool dark;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        decoration: BoxDecoration(
          color: dark ? const Color(0x33000000) : const Color(0x14000000),
          borderRadius: BorderRadius.circular(6),
          border: const Border(
            left: BorderSide(color: Color(0xFF25D366), width: 3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFF25D366),
              ),
            ),
            Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: dark ? const Color(0xFFE9EDEF) : const Color(0xFF111B21),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatPicture extends StatefulWidget {
  const _ChatPicture({required this.message, required this.threadId});

  final ChatMessage message;
  final String threadId;

  @override
  State<_ChatPicture> createState() => _ChatPictureState();
}

class _ChatPictureState extends State<_ChatPicture> {
  Uint8List? _bytes;
  bool _waiting = false;
  bool _failed = false;
  DateTime? _startedAt;

  void _retry() {
    setState(() {
      _failed = false;
      _startedAt = null;
    });
    _load();
  }

  @override
  void initState() {
    super.initState();
    _bytes = _copy(widget.message.localBytes);
    ChatImageStore.revision.addListener(_onStore);
    if (_bytes == null) _load();
  }

  @override
  void didUpdateWidget(_ChatPicture old) {
    super.didUpdateWidget(old);
    final local = _copy(widget.message.localBytes);
    if (local != null) {
      _bytes = local;
      return;
    }
    if (old.message.photo != widget.message.photo) _load();
  }

  @override
  void dispose() {
    ChatImageStore.revision.removeListener(_onStore);
    super.dispose();
  }

  void _onStore() {
    if (_bytes == null) _load();
  }

  Future<void> _load() async {
    final id = widget.message.photo;
    if (id.isEmpty) return;
    _startedAt ??= DateTime.now();
    var bytes = await ChatImageStore.load(id);
    if (!mounted) return;
    if (bytes == null || bytes.isEmpty) {
      // Ask the sender's device too, but fetch the server copy right away
      // instead of only waiting for the peer to come online.
      ChatLive.instance.wantPhoto(widget.threadId, id);
      try {
        bytes = await ChatImages.fetch(id).timeout(const Duration(seconds: 25));
      } catch (_) {
        bytes = null;
      }
      if (!mounted || widget.message.photo != id) return;
      if (_bytes != null) return;
      if (bytes != null && bytes.isNotEmpty) {
        unawaited(ChatImageStore.save(id, bytes));
      }
    }
    if (bytes == null || bytes.isEmpty) {
      if (DateTime.now().difference(_startedAt!) > const Duration(seconds: 45)) {
        if (!_failed) setState(() => _failed = true);
      }
      ChatLive.instance.wantPhoto(widget.threadId, id);
      if (_waiting) return;
      _waiting = true;
      Future<void>.delayed(const Duration(seconds: 4), () {
        _waiting = false;
        if (mounted && _bytes == null && widget.message.photo == id) _load();
      });
      return;
    }
    final got = bytes;
    setState(() {
      _failed = false;
      _bytes = Uint8List.fromList(got);
    });
  }

  Uint8List? _copy(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return null;
    return Uint8List.fromList(bytes);
  }

  void _open() {
    final bytes = _bytes;
    if (bytes == null) return;
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (context, animation, secondary) {
          return _PhotoPage(bytes: bytes);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    final child = bytes == null && _failed
        ? GestureDetector(
            onTap: _retry,
            child: const SizedBox(
              height: 180,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.refresh_rounded),
                    SizedBox(height: 6),
                    Text('Photo not loaded. Tap to retry'),
                  ],
                ),
              ),
            ),
          )
        : bytes == null
        ? const SizedBox(
            height: 180,
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        : GestureDetector(
            onTap: _open,
            child: Image.memory(
              bytes,
              height: 180,
              width: double.infinity,
              cacheHeight: 540,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (context, error, stack) => const SizedBox(
                height: 180,
                child: Center(child: Icon(Icons.image_outlined)),
              ),
            ),
          );
    return ClipRRect(borderRadius: BorderRadius.circular(6), child: child);
  }
}

class _PhotoPage extends StatelessWidget {
  const _PhotoPage({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, color: Colors.white),
              ),
            ),
          ),
        ],
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
    this.reserve = 0,
  });

  final String text;
  final List<String> links;
  final Color color;
  final Color linkColor;
  final ValueChanged<String> onLink;
  final double reserve;

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
          if (reserve > 0)
            WidgetSpan(child: SizedBox(width: reserve, height: 14)),
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
