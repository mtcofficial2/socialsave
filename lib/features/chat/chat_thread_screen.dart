import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/chat/chat_alerts.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_drafts.dart';
import 'package:social_save/features/chat/emoji_panel.dart';
import 'package:social_save/features/chat/emoji_text.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/features/chat/chat_history.dart';
import 'package:social_save/features/chat/chat_image_store.dart';
import 'package:social_save/features/chat/chat_link.dart';
import 'package:social_save/features/chat/chat_live.dart';
import 'package:social_save/features/chat/chat_outbox.dart';
import 'package:social_save/features/chat/chat_call.dart';
import 'package:social_save/features/chat/chat_prefs.dart';
import 'package:social_save/features/chat/chat_profile.dart';
import 'package:social_save/features/chat/chat_services.dart';
import 'package:social_save/features/chat/chat_status_screen.dart';
import 'package:social_save/features/chat/chat_ui.dart';
import 'package:social_save/features/chat/chat_ux.dart';
import 'package:social_save/features/chat/chat_voice.dart';
import 'package:social_save/features/chat/chat_wall.dart';
import 'package:social_save/features/chat/chat_wallpaper.dart';
import 'package:social_save/shared/widgets/app_snack.dart';
import 'package:social_save/core/diagnostics/quiet_log.dart';
import 'package:social_save/core/theme/app_tokens.dart';
import 'package:social_save/shared/widgets/empty_state.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:social_save/features/chat/chat_alert_policy.dart';

/// A direct chat. On a phone this is its own page. On a wide window it sits
/// beside the chat list.
class ChatThreadScreen extends StatelessWidget {
  const ChatThreadScreen({
    super.key,
    required this.threadId,
    required this.username,
    this.seenName = '',
    this.group = false,
    this.statusQuote = '',
  });

  final String threadId;
  final String username;

  /// Private name for this chat. Blank shows [username].
  final String seenName;

  /// A group chat. The title is the group name, not a username.
  final bool group;

  /// Status line to quote when this chat was opened from a reply.
  final String statusQuote;

  @override
  Widget build(BuildContext context) {
    return ChatThreadView(
      threadId: threadId,
      username: username,
      seenName: seenName,
      group: group || threadId.startsWith('g'),
      statusQuote: statusQuote,
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
    this.statusQuote = '',
    this.onRead,
    this.onSeenName,
    this.onLeft,
  });

  final String threadId;
  final String username;
  final String seenName;
  final bool group;
  final bool embedded;
  final String statusQuote;
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
  DateTime? _polledAt;
  String _me = '';
  String? _error;
  bool _starting = true;
  bool _refreshing = false;
  bool _stickToEnd = true;
  bool _recording = false;
  bool _emojiOpen = false;
  bool _finishingVoice = false;
  int _below = 0;
  // How many of the newest messages the list builds. Older ones are added a
  // page at a time as you scroll up, so long chats open light.
  int _window = chatThreadFirstPage;
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
  // Bumped when the peer starts or stops typing or recording. Only the
  // activity lines listen, so a typing blip no longer rebuilds the thread.
  final ValueNotifier<int> _activityTick = ValueNotifier<int>(0);
  StreamSubscription<ChatLiveEvent>? _live;
  StreamSubscription<List<ConnectivityResult>>? _net;
  Timer? _resendTimer;
  bool _resending = false;
  final Map<int, GlobalKey> _rowKeys = {};
  int _localSeq = 0;
  int? _replyId;
  String _replyName = '';
  String _replyText = '';
  bool _statusReply = false;
  final Set<int> _selected = <int>{};
  final TextEditingController _search = TextEditingController();
  bool _searching = false;
  bool _blocked = false;
  bool _request = false;
  List<int> _pinned = const [];
  List<String> _members = const [];
  String _about = '';
  String _rules = '';
  bool _announce = false;
  String _owner = '';
  List<String> _admins = const [];
  int _vanish = 0;
  int _syncedAt = 0;
  int? _editingId;
  int _pinCursor = 0;
  bool _landed = false;
  int? _flashId;
  Timer? _flashTimer;
  int _searchCursor = 0;
  String? _mentionQuery;
  bool _voiceCancel = false;
  bool _voiceLockArm = false;
  bool _voiceLocked = false;
  bool _voiceHolding = false;
  bool _voiceReleasePending = false;
  bool _voiceReleaseSend = true;
  String _voiceHint = '';
  String _wallMode = ChatWalls.modeDefault;
  Uint8List? _wallBytes;

  bool get _isGroup => _group || widget.group || _threadId.startsWith('g');

  bool get _keyboardSends => ChatPrefs.keyboardSends;

  bool get _imeSends => ChatPrefs.imeSends(
    keyboardSends: _keyboardSends,
    platform: Theme.of(context).platform,
  );

  void _onPrefs() {
    if (mounted) setState(() {});
  }

  /// A recoverable problem after something the user did (send, attach,
  /// record, delete...): a short snackbar instead of the red banner, which
  /// stays for "chat not found" and a chat that could not load at all.
  void _chatProblem(String? text) {
    if (!mounted || text == null || text.trim().isEmpty) return;
    AppSnack.error(context, text);
  }

  /// A how-to hint (not a failure), such as "Hold to record".
  void _chatHint(String text) {
    if (!mounted) return;
    AppSnack.info(context, text);
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
    ChatPrefs.revision.addListener(_onPrefs);
    unawaited(ChatPrefs.ensure());
    ChatAlerts.holdThread(_threadId);
    _live = ChatLive.instance.events.listen(_onLive);
    ChatLive.instance.connected.addListener(_onLiveConnection);
    try {
      _net = Connectivity().onConnectivityChanged.listen(
        (results) {
          if (!results.contains(ConnectivityResult.none)) {
            _scheduleResend();
          }
        },
        onError: (Object e) => logQuiet('chat_thread.connectivity', e),
      );
    } catch (e) {
      logQuiet('chat_thread.connectivity', e);
    }
    ChatLive.revision.addListener(_onTypingClock);
    _scroll.addListener(_onScroll);
    _text.addListener(_onDraftChanged);
    unawaited(_loadWall());
    _recorder.onLimit = () {
      if (!mounted) return;
      unawaited(_finishVoice(send: true));
    };
    unawaited(_open());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ChatPrefs.revision.removeListener(_onPrefs);
    ChatAlerts.releaseThread(_threadId);
    _live?.cancel();
    ChatLive.revision.removeListener(_onTypingClock);
    ChatLive.instance.connected.removeListener(_onLiveConnection);
    _net?.cancel();
    _resendTimer?.cancel();
    ChatLive.instance.typing(_threadId, on: false);
    ChatLive.instance.recording(_threadId, on: false);
    _poll?.cancel();
    _flashTimer?.cancel();
    _draftTimer?.cancel();
    _typingIdle?.cancel();
    _typingClock?.cancel();
    _activityTick.dispose();
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
    // The list is reversed: offset 0 is the newest message at the bottom.
    final position = _scroll.position;
    if (position.maxScrollExtent - position.pixels < 800 &&
        _window < _shown.length) {
      setState(() => _window = chatThreadNextWindow(_window, _shown.length));
    }
    final distance = position.pixels;
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
    _syncMentions();
  }

  void _onTyped(String _) {
    _noteTyping(force: true);
    _syncMentions();
  }

  void _syncMentions() {
    final next = !_isGroup
        ? null
        : chatMentionQuery(_text.text, _text.selection.extentOffset);
    if (next == _mentionQuery) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final fresh = !_isGroup
          ? null
          : chatMentionQuery(_text.text, _text.selection.extentOffset);
      if (fresh == _mentionQuery) return;
      setState(() => _mentionQuery = fresh);
    });
  }

  List<String> get _mentionChoices {
    final query = (_mentionQuery ?? '').toLowerCase();
    final me = _me.replaceFirst(RegExp(r'^@'), '').trim().toLowerCase();
    return [
      for (final name in _members)
        if (name.toLowerCase() != me &&
            (query.isEmpty || name.toLowerCase().startsWith(query)))
          name,
    ];
  }

  void _insertMention(String name) {
    final text = _text.text;
    final caret = _text.selection.extentOffset.clamp(0, text.length);
    final match = RegExp(
      r'(^|[\s\n])@([A-Za-z0-9_]{0,20})$',
    ).firstMatch(text.substring(0, caret));
    if (match == null) return;
    final start = match.start + (match.group(1) ?? '').length;
    final next = '${text.substring(0, start)}@$name ${text.substring(caret)}';
    _text.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + name.length + 2),
    );
    setState(() => _mentionQuery = null);
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
    _activityTick.value++;
    _typingClock?.cancel();
    final live =
        ChatLive.isTyping(_threadId) ||
        ChatLive.isRecording(_threadId);
    if (!live) return;
    _typingClock = Timer(const Duration(seconds: 4), () {
      if (mounted) _activityTick.value++;
    });
  }

  void _onLive(ChatLiveEvent event) {
    if (!mounted ||
        event.type == 'typing' ||
        event.type == 'recording' ||
        event.type == 'call' ||
        event.type.startsWith('call-')) {
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

  /// Brings a message into view. Its page is loaded first, then the list
  /// steps toward its row by position until the row is built, and finally
  /// lines it up near the top (the list is reversed, so 0.8 is near the top).
  void _scrollToMessage(int id, {int attempt = 0}) {
    if (!mounted) return;
    final index = _shown.indexWhere((item) => item.id == id);
    if (index < 0) return;
    final needed = chatThreadWindowFor(index, _shown.length, _window);
    if (needed != _window) {
      setState(() => _window = needed);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToMessage(id, attempt: attempt),
      );
      return;
    }
    final current = _rowKeys[id]?.currentContext;
    if (current != null) {
      unawaited(
        Scrollable.ensureVisible(
          current,
          duration: attempt == 0 ? const Duration(milliseconds: 220) : Duration.zero,
          alignment: 0.8,
        ),
      );
      return;
    }
    if (attempt >= 8 || !_scroll.hasClients) return;
    final rows = _rows();
    final row = rows.indexWhere((item) => item.message?.id == id);
    if (row < 0) return;
    final position = _scroll.position;
    final target = chatReversedOffsetGuess(
      row: row,
      rows: rows.length,
      maxExtent: position.maxScrollExtent,
    );
    _scroll.jumpTo(target);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollToMessage(id, attempt: attempt + 1),
    );
  }

  /// Keeps what you are reading in place while new messages arrive below.
  /// The list is reversed, so rows added at the bottom would otherwise push
  /// everything up.
  void _holdView() {
    if (!_scroll.hasClients || _scroll.position.pixels < 1) return;
    int? anchorId;
    double? before;
    for (final entry in _rowKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      anchorId = entry.key;
      before = box.localToGlobal(Offset.zero).dy;
      break;
    }
    if (anchorId == null || before == null) return;
    final id = anchorId;
    final oldDy = before;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final box = _rowKeys[id]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) return;
      final shift = box.localToGlobal(Offset.zero).dy - oldDy;
      if (shift.abs() < 0.5) return;
      final position = _scroll.position;
      _scroll.jumpTo(
        (position.pixels - shift).clamp(0.0, position.maxScrollExtent),
      );
    });
  }

  void _applyLand(List<ChatMessage> messages, {required bool finish}) {
    if (_landed) return;
    final hasUnread = messages.any(
      (item) => item.name != _me && item.id > _seenAtOpen && item.id > 0,
    );
    if (!hasUnread && !finish) return;
    _landed = true;
    _bannerAfter = hasUnread ? _seenAtOpen : -1;
    if (hasUnread) _stickToEnd = false;
  }

  void _jumpToUnread() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ChatMessage? target;
      for (final message in _messages) {
        if (message.name != _me && message.id > _bannerAfter && message.id > 0) {
          target = message;
          break;
        }
      }
      if (target == null) {
        _jump(animate: false);
        return;
      }
      _scrollToMessage(target.id);
    });
  }

  void _flash(int id) {
    _flashTimer?.cancel();
    setState(() => _flashId = id);
    _flashTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(() {
        if (_flashId == id) _flashId = null;
      });
    });
  }

  void _onQuote(int id) {
    _scrollToMessage(id);
    _flash(id);
  }

  List<int> get _searchHits => chatSearchHitIds(_messages, _search.text);

  String get _searchLabel {
    if (_search.text.trim().isEmpty) return '';
    final hits = _searchHits;
    if (hits.isEmpty) return 'No matches';
    final index = _searchCursor.clamp(0, hits.length - 1);
    return '${index + 1} of ${hits.length}';
  }

  void _onSearchChanged(String _) {
    final hits = chatSearchHitIds(_messages, _search.text);
    setState(() => _searchCursor = hits.isEmpty ? 0 : hits.length - 1);
    if (hits.isNotEmpty) _scrollToMessage(hits.last);
  }

  void _moveSearch(int delta) {
    final hits = _searchHits;
    if (hits.isEmpty) return;
    var next = (_searchCursor + delta) % hits.length;
    if (next < 0) next += hits.length;
    setState(() => _searchCursor = next);
    _scrollToMessage(hits[next]);
  }

  bool _isSearchHit(int id) {
    if (!_searching || _search.text.trim().isEmpty) return false;
    final hits = _searchHits;
    if (hits.isEmpty) return false;
    final index = _searchCursor.clamp(0, hits.length - 1);
    return hits[index] == id;
  }

  Future<void> _loadWall() async {
    final id = _threadId;
    final mode = await ChatWalls.mode(id);
    final bytes = mode == ChatWalls.modePhoto ? await ChatWalls.photo(id) : null;
    if (!mounted || id != _threadId) return;
    setState(() {
      _wallMode = mode;
      _wallBytes = bytes;
    });
  }

  bool get _wallPattern {
    if (_wallMode == ChatWalls.modePlain || _wallMode == ChatWalls.modePhoto) {
      return false;
    }
    if (_wallMode == ChatWalls.modePattern) return true;
    return ChatPrefs.pattern;
  }

  ImageProvider? get _wallImage {
    final bytes = _wallBytes;
    if (_wallMode != ChatWalls.modePhoto || bytes == null || bytes.isEmpty) {
      return null;
    }
    return MemoryImage(bytes);
  }

  Future<void> _open() async {
    final quote = widget.statusQuote.trim();
    if (quote.isNotEmpty) {
      _statusReply = true;
      _replyName = 'Status';
      _replyText = quote;
    }
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
        _error = null;
        _applyLand(merged, finish: false);
        _starting = false;
      });
      if (_landed && _bannerAfter >= 0) {
        _jumpToUnread();
      } else if (_landed) {
        _jump(animate: false);
      }
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
      if (!chatPollDue(
        live: ChatLive.instance.connected.value,
        last: _polledAt,
        now: DateTime.now(),
      )) {
        return;
      }
      unawaited(_refresh());
    });
  }

  Future<void> _refresh() async {
    if (_refreshing || _threadId.isEmpty) return;
    _refreshing = true;
    _polledAt = DateTime.now();
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
          sync.peerRequest != _request ||
          sync.groupAbout != _about ||
          sync.groupRules != _rules ||
          sync.groupAnnounce != _announce ||
          sync.groupOwner != _owner ||
          sync.groupAdmins.join('\n') != _admins.join('\n') ||
          sync.vanish != _vanish ||
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
      _request = sync.peerRequest;
      _about = sync.groupAbout;
      _rules = sync.groupRules;
      _announce = sync.groupAnnounce;
      _owner = sync.groupOwner;
      _admins = sync.groupAdmins;
      _vanish = sync.vanish;
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
        final previous = combined[index];
        if (next.text != previous.text ||
            next.editedAt != previous.editedAt ||
            next.reactions.length != previous.reactions.length ||
            next.poll?.closed != previous.poll?.closed ||
            next.poll?.votes.length != previous.poll?.votes.length ||
            next.call != previous.call ||
            next.callMs != previous.callMs) {
          combined[index] = next;
          touched = true;
        }
      }
      final changed =
          fresh.isNotEmpty || base.length != _messages.length || touched;
      if (!changed && !_starting) {
        if (!_landed) {
          _applyLand(combined, finish: true);
          if (_bannerAfter >= 0) {
            _jumpToUnread();
          } else if (_stickToEnd) {
            _jump(animate: false);
          }
          if (mounted) setState(() {});
        }
        if (presenceChanged || _error != null) setState(() => _error = null);
        if (_messages.any((item) => item.status == 'queued')) _scheduleResend();
        if (presenceChanged) _remember();
        unawaited(_noteRead());
        return;
      }
      final wasStarting = _starting;
      final landedBefore = _landed;
      _applyLand(combined, finish: true);
      final justLanded = !landedBefore && _landed;
      final stick = _stickToEnd;
      if (!stick && fresh.isNotEmpty) _holdView();
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
      if (stick) {
        _jump(animate: !wasStarting && fresh.isNotEmpty);
      } else if (justLanded) {
        _jumpToUnread();
      }
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
        _landed = false;
      });
      unawaited(_loadWall());
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
    if (local.pendingKind == 'file' || local.pendingKind == 'clip') {
      return server.isFile && server.fileName == local.fileName;
    }
    return !server.isVoice &&
        !server.isPhoto &&
        !server.isSong &&
        !server.isFile &&
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
      // Reversed list: the newest message sits at offset 0.
      const target = 0.0;
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

  /// The empty chat's quick-send chip.
  void _sayHi() {
    if (_threadId.isEmpty || _recording) return;
    _text.text = 'Hi 👋';
    unawaited(_send());
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
        _chatProblem(chatErrorText(error));
      }
      return;
    }
    unawaited(HapticFeedback.lightImpact());
    final status = _statusReply && _replyText.trim().isNotEmpty;
    final body = status ? statusReplyBody(_replyText, text) : text;
    final reply = status ? 0 : (_replyId ?? 0);
    final replyName = status ? '' : _replyName;
    final replyText = status ? '' : _replyText;
    final local = _pending(
      text: body,
      reply: reply,
      replyName: replyName,
      replyText: replyText,
    );
    _clearComposer();
    _accept(local);
    try {
      final message = await _api.send(_threadId, body, reply: reply);
      if (!mounted) return;
      _replaceLocal(local.id, message);
    } catch (error) {
      if (mounted && _chatGone(error) && await _reopen()) {
        try {
          final message = await _api.send(_threadId, body);
          if (!mounted) return;
          _replaceLocal(local.id, message);
          return;
        } catch (e) { logQuiet('chat_thread_screen', e); }
      }
      if (mounted && _messages.any((item) => item.id == local.id)) {
        _markFailed(local.id, error);
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
    if (isNew && !stick) _holdView();
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
                subtitle: const Text('pdf, office, text, or zip'),
                minTileHeight: 48,
                onTap: () => Navigator.pop(context, 'document'),
              ),
              ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: const Text('Short clip'),
                minTileHeight: 48,
                onTap: () => Navigator.pop(context, 'clip'),
              ),
              ListTile(
                leading: const Icon(Icons.music_note_outlined),
                title: const Text('Saved song'),
                subtitle: const Text('A song already saved in SocialSave'),
                minTileHeight: 48,
                onTap: () => Navigator.pop(context, 'song'),
              ),
              ListTile(
                leading: const Icon(Icons.poll_outlined),
                title: const Text('Poll'),
                minTileHeight: 48,
                onTap: () => Navigator.pop(context, 'poll'),
              ),
              ListTile(
                leading: const Icon(Icons.contact_page_outlined),
                title: const Text('Contact'),
                minTileHeight: 48,
                onTap: () => Navigator.pop(context, 'card'),
              ),
              ListTile(
                leading: const Icon(Icons.place_outlined),
                title: const Text('Place'),
                minTileHeight: 48,
                onTap: () => Navigator.pop(context, 'place'),
              ),
              ListTile(
                leading: const Icon(Icons.schedule_send_outlined),
                title: const Text('Schedule'),
                minTileHeight: 48,
                onTap: () => Navigator.pop(context, 'schedule'),
              ),
              ListTile(
                leading: const Icon(Icons.schedule_outlined),
                title: const Text('Scheduled messages'),
                minTileHeight: 48,
                onTap: () => Navigator.pop(context, 'scheduled'),
              ),
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: const Text('Disappearing messages'),
                minTileHeight: 48,
                onTap: () => Navigator.pop(context, 'timer'),
              ),
              ListTile(
                leading: const Icon(Icons.notifications_outlined),
                title: const Text('Notifications'),
                minTileHeight: 48,
                onTap: () => Navigator.pop(context, 'notify'),
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
    if (choice == 'clip') {
      await _pickClip();
      return;
    }
    if (choice == 'song') {
      await _pickSong();
      return;
    }
    if (choice == 'poll') {
      await _sendPoll();
      return;
    }
    if (choice == 'card') {
      await _sendCard();
      return;
    }
    if (choice == 'place') {
      await _sendPlace();
      return;
    }
    if (choice == 'schedule') {
      await _scheduleCurrent();
      return;
    }
    if (choice == 'scheduled') {
      await showScheduledMessages(context, _threadId);
      return;
    }
    if (choice == 'timer') {
      await _setVanish();
      return;
    }
    if (choice == 'notify') {
      await _setNotify();
      return;
    }
    await _pickPhoto();
  }

  Future<void> _capturePhoto() async {
    if (!Plat.isAndroid || _recording || _threadId.isEmpty) return;
    final status = await Permission.camera.request();
    if (!mounted) return;
    if (!status.isGranted) {
      _chatProblem('Allow the camera to take a photo.');
      return;
    }
    String? path;
    try {
      path = await const MethodChannel(
        'socialsave/media',
      ).invokeMethod<String>('capturePhoto');
    } catch (error) {
      if (!mounted) return;
      _chatProblem(chatErrorText(error));
      return;
    }
    if (path == null || path.isEmpty || !mounted) return;
    try {
      final raw = await File(path).readAsBytes();
      final fitted = await fitChatImage(raw);
      if (!mounted) return;
      await _previewAndSend([fitted]);
    } catch (error) {
      if (!mounted) return;
      _chatProblem(error is StateError
            ? error.message
            : chatErrorText(error)
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
      _chatProblem(chatErrorText(error));
      return;
    }
    if (!mounted) return;
    if (songs.isEmpty) {
      _chatProblem('No saved song under 16 MB is on this device.'
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
        _chatProblem('That song is too large to send in chat.');
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
        _markFailed(localId, error);
        return;
      }
      _chatProblem(chatErrorText(error));
    }
  }

  Future<void> _pickDocument() async {
    await _pickAttachment(clip: false);
  }

  Future<void> _pickClip() async {
    await _pickAttachment(clip: true);
  }

  Future<void> _pickAttachment({required bool clip}) async {
    if (_recording || _threadId.isEmpty) return;
    final picked = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(
          label: clip ? 'Short clips' : 'Documents',
          extensions: (clip ? chatClipExtensions : chatDocExtensions).toList(),
        ),
      ],
    );
    if (picked == null || !mounted) return;
    final name = picked.name;
    if (clip ? !chatIsClipName(name) : !chatIsDocumentName(name)) {
      _chatHint(clip ? 'Choose a short clip.' : 'Choose a document.');
      return;
    }
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    final cap = clip ? chatClipMaxBytes : chatDocMaxBytes;
    if (bytes.length > cap) {
      _chatProblem(clip
            ? 'That short clip is too large.'
            : 'That document is too large.'
      );
      return;
    }
    if (bytes.isEmpty) {
      _chatHint('Choose a file first.');
      return;
    }
    await _sendChosenFile(bytes, name: name, clip: clip);
  }

  Future<void> _sendChosenFile(
    Uint8List bytes, {
    required String name,
    required bool clip,
  }) async {
    int? localId;
    try {
      final reply = _replyId ?? 0;
      final replyName = _replyName;
      final replyText = _replyText;
      final local = _pending(
        text: '',
        kind: clip ? 'clip' : 'file',
        bytes: bytes,
        reply: reply,
        replyName: replyName,
        replyText: replyText,
        fileName: name,
        fileSize: bytes.length,
        clip: clip,
      );
      localId = local.id;
      _replyId = null;
      _replyName = '';
      _replyText = '';
      _statusReply = false;
      _accept(local);
      final message = await _api.sendFile(
        _threadId,
        bytes,
        name: name,
        reply: reply,
        clip: clip,
      );
      if (!mounted || !_messages.any((item) => item.id == local.id)) return;
      _replaceLocal(local.id, message);
    } catch (error) {
      if (!mounted) return;
      if (localId != null && _messages.any((item) => item.id == localId)) {
        _markFailed(localId, error);
        return;
      }
      _chatProblem(chatErrorText(error));
    }
  }

  Future<void> _openAttachment(ChatMessage message) async {
    try {
      final bytes = message.localBytes ??
          (message.file.isEmpty ? null : await _api.chatFile(message.file));
      if (!mounted) return;
      if (bytes == null || bytes.isEmpty) {
        _chatProblem('That file was not found.');
        return;
      }
      if (kIsWeb) return;
      final dir = await getTemporaryDirectory();
      final safe = message.fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final path = p.join(dir.path, safe.isEmpty ? 'file' : safe);
      await File(path).writeAsBytes(bytes, flush: true);
      await OpenFilex.open(path);
    } catch (error) {
      if (!mounted) return;
      _chatProblem(chatErrorText(error));
    }
  }

  Future<void> _pickPhoto() async {
    if (_recording || _threadId.isEmpty) return;
    final fitted = <Uint8List>[];
    try {
      final picked = await openFiles(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Photos', extensions: ['jpg', 'jpeg', 'png']),
        ],
      );
      if (picked.isEmpty || !mounted) return;
      for (final file in picked.take(chatPhotoSetMax)) {
        final raw = await file.readAsBytes();
        fitted.add(await fitChatImage(raw));
      }
    } catch (error) {
      if (!mounted) return;
      _chatProblem(error is StateError
            ? error.message
            : chatErrorText(error)
      );
      return;
    }
    if (!mounted || fitted.isEmpty) return;
    await _previewAndSend(fitted);
  }

  Future<void> _previewAndSend(List<Uint8List> photos) async {
    if (photos.isEmpty || !mounted) return;
    final caption = await showChatPhotoPreview(context, photos);
    if (caption == null || !mounted) return;
    for (var i = 0; i < photos.length; i++) {
      await _sendFittedPhoto(
        photos[i],
        caption: i == 0 ? caption : '',
        quote: i == 0,
      );
    }
  }

  Future<void> _sendFittedPhoto(
    Uint8List fitted, {
    String? caption,
    bool quote = true,
  }) async {
    int? localId;
    try {
      final fromPreview = caption != null;
      final typed = fromPreview ? caption.trim() : _text.text.trim();
      final status = quote && _statusReply && _replyText.trim().isNotEmpty;
      final body = status ? statusReplyBody(_replyText, typed) : typed;
      final reply = !quote || status ? 0 : (_replyId ?? 0);
      final replyName = !quote || status ? '' : _replyName;
      final replyText = !quote || status ? '' : _replyText;
      final stored = body.isEmpty ? 'Photo' : body;
      final local = _pending(
        text: stored,
        kind: 'photo',
        bytes: fitted,
        reply: reply,
        replyName: replyName,
        replyText: replyText,
      );
      localId = local.id;
      if (fromPreview) {
        if (quote) {
          _replyId = null;
          _replyName = '';
          _replyText = '';
          _statusReply = false;
        }
      } else {
        _clearComposer();
      }
      _accept(local);
      final outgoing = await _api.sendPhoto(
        _threadId,
        fitted,
        caption: body,
        reply: reply,
      );
      await _storePhoto(outgoing, fitted);
      if (!mounted || !_messages.any((item) => item.id == local.id)) return;
      _replaceLocal(local.id, outgoing.message);
    } catch (error) {
      if (!mounted) return;
      if (localId != null && _messages.any((item) => item.id == localId)) {
        _markFailed(localId, error);
        return;
      }
      if (localId != null) return;
      _chatProblem(error is StateError ? error.message : chatErrorText(error)
      );
    }
  }

  /// A send that could not reach the server waits as "queued" and goes out
  /// again on its own; any other failure stays "failed" for tap-to-retry.
  void _markFailed(int id, Object error) {
    _mark(id, chatIsOffline(error) ? 'queued' : 'failed');
  }

  void _onLiveConnection() {
    if (ChatLive.instance.connected.value) _scheduleResend();
  }

  /// Waits a moment (networks flap when they come back), then resends.
  void _scheduleResend() {
    if (!mounted || !_messages.any((item) => item.status == 'queued')) return;
    _resendTimer?.cancel();
    _resendTimer = Timer(const Duration(milliseconds: 1200), () {
      unawaited(_resendQueued());
    });
  }

  /// Sends every queued message again, oldest first. A message the server
  /// already has (the first try got through before the line dropped) is
  /// matched against the fresh history and removed instead of sent twice.
  /// Stops at the first one that is still offline.
  Future<void> _resendQueued() async {
    if (_resending || !mounted) return;
    // The background outbox is sending this chat's queue right now; look
    // again in a moment so nothing is sent twice.
    if (ChatOutbox.sending == _threadId) {
      _resendTimer?.cancel();
      _resendTimer = Timer(const Duration(seconds: 2), () => unawaited(_resendQueued()));
      return;
    }
    _resending = true;
    try {
      await _refresh();
      if (!mounted) return;
      final queued = chatResendOrder(_messages);
      for (final message in queued) {
        if (!mounted) return;
        final current = _messages.where((item) => item.id == message.id);
        if (current.isEmpty || current.first.status != 'queued') continue;
        if (chatAlreadyDelivered(message, _messages, me: _me)) {
          _drop(message.id);
          continue;
        }
        await _retry(current.first);
        if (!mounted) return;
        final after = _messages.where((item) => item.id == message.id);
        if (after.isNotEmpty && after.first.status == 'queued') break;
      }
    } finally {
      _resending = false;
    }
  }

  Future<void> _retry(ChatMessage message) async {
    if (message.id >= 0 || message.status == 'sending') return;
    _mark(message.id, 'sending');
    try {
      final sent = await chatSendPending(_api, _threadId, message);
      if (!mounted || !_messages.any((item) => item.id == message.id)) return;
      _replaceLocal(message.id, sent);
    } catch (error) {
      // A lost chat gets a fresh id, so the next tap on retry goes through.
      if (mounted && _chatGone(error)) await _reopen();
      if (mounted && _messages.any((item) => item.id == message.id)) {
        _markFailed(message.id, error);
      }
    }
  }

  ChatMessage _pending({
    required String text,
    String kind = '',
    Uint8List? bytes,
    int voiceMs = 0,
    String voiceLevels = '',
    String songName = '',
    int songMs = 0,
    int reply = 0,
    String replyName = '',
    String replyText = '',
    String fileName = '',
    int fileSize = 0,
    bool clip = false,
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
      voiceLevels: voiceLevels,
      songName: songName,
      songMs: songMs,
      reply: reply,
      replyName: replyName,
      replyText: replyText,
      localBytes: bytes,
      pendingKind: kind,
      fileName: fileName,
      fileSize: fileSize,
      clip: clip,
    );
  }

  void _clearComposer() {
    _text.clear();
    _replyId = null;
    _replyName = '';
    _replyText = '';
    _statusReply = false;
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
      _statusReply = false;
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

  void _onMicTap() {
    unawaited(HapticFeedback.selectionClick());
    _chatHint('Hold the mic to record a voice note.');
  }

  void _onMicHoldStart(LongPressStartDetails _) {
    _voiceCancel = false;
    _voiceLockArm = false;
    _voiceHolding = true;
    _voiceReleasePending = false;
    unawaited(HapticFeedback.mediumImpact());
    setState(() => _voiceHint = 'Slide left to cancel. Slide up to lock.');
    unawaited(_startVoice());
  }

  void _onMicHoldMove(LongPressMoveUpdateDetails details) {
    final cancel = details.offsetFromOrigin.dx < -72;
    final lock = details.offsetFromOrigin.dy < -72 && !cancel;
    if (cancel == _voiceCancel && lock == _voiceLockArm) return;
    if ((cancel && !_voiceCancel) || (lock && !_voiceLockArm)) {
      unawaited(HapticFeedback.selectionClick());
    }
    setState(() {
      _voiceCancel = cancel;
      _voiceLockArm = lock;
      _voiceHint = cancel
          ? 'Release to cancel'
          : lock
          ? 'Release to lock'
          : 'Slide left to cancel. Slide up to lock.';
    });
  }

  void _onMicHoldEnd(LongPressEndDetails _) {
    final lock = _voiceLockArm && !_voiceCancel;
    final send = !_voiceCancel;
    _voiceHolding = false;
    _voiceLockArm = false;
    _voiceCancel = false;
    if (lock) {
      unawaited(HapticFeedback.heavyImpact());
      setState(() {
        _voiceLocked = true;
        _voiceHint = '';
      });
      return;
    }
    if (!send) unawaited(HapticFeedback.lightImpact());
    setState(() => _voiceHint = '');
    if (!_recording) {
      _voiceReleasePending = true;
      _voiceReleaseSend = send;
      return;
    }
    unawaited(_finishVoice(send: send));
  }

  Future<void> _startVoice() async {
    if (_recording || _threadId.isEmpty || Plat.isWeb) return;
    final problem = await _recorder.begin();
    if (!mounted) return;
    if (problem != null) {
      _voiceReleasePending = false;
      setState(() {
        _voiceHolding = false;
        _voiceHint = '';
      });
      _chatProblem(problem);
      return;
    }
    setState(() {
      _recording = true;
      _error = null;
    });
    ChatLive.instance.typing(_threadId, on: false);
    ChatLive.instance.recording(_threadId, on: true);
    if (_voiceReleasePending) {
      final send = _voiceReleaseSend;
      _voiceReleasePending = false;
      await _finishVoice(send: send);
    }
  }

  Future<void> _finishVoice({required bool send}) async {
    if (_finishingVoice) return;
    _finishingVoice = true;
    ChatLive.instance.recording(_threadId, on: false);
    var voiceLocal = 0;
    try {
      final taken = await _recorder.stop(send: send);
      if (!mounted) return;
      setState(() {
        _recording = false;
        _voiceLocked = false;
        _voiceHolding = false;
        _voiceHint = '';
      });
      if (!send || taken == null) return;
      if (taken.ms < 500) {
        _chatProblem('That voice note was too short.');
        return;
      }
      final file = File(taken.path);
      final bytes = await file.readAsBytes();
      unawaited(file.delete());
      if (!mounted) return;
      if (bytes.isEmpty) {
        _chatProblem('That voice note could not be sent.');
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
        voiceLevels: taken.levels,
        reply: reply,
        replyName: replyName,
        replyText: replyText,
      );
      _replyId = null;
      _replyName = '';
      _replyText = '';
      _statusReply = false;
      voiceLocal = local.id;
      _accept(local);
      final message = await _api.sendVoice(
        _threadId,
        bytes,
        ms,
        reply: reply,
        levels: taken.levels,
      );
      if (!mounted || !_messages.any((item) => item.id == voiceLocal)) return;
      _replaceLocal(voiceLocal, message);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _recording = false;
        _voiceLocked = false;
        _voiceHolding = false;
        _voiceHint = '';
      });
      if (voiceLocal < 0 && _messages.any((item) => item.id == voiceLocal)) {
        _markFailed(voiceLocal, error);
        return;
      }
      if (voiceLocal < 0) return;
      _chatProblem(chatErrorText(error));
    } finally {
      _finishingVoice = false;
    }
  }

  void _openLink(String url) {
    context.push('/preview', extra: url);
  }

  void _toggleEmoji() {
    if (_emojiOpen) {
      setState(() => _emojiOpen = false);
      _focus.requestFocus();
      return;
    }
    _focus.unfocus();
    setState(() => _emojiOpen = true);
  }

  void _insertEmoji(String emoji) {
    final value = _text.value;
    final text = value.text;
    final start = value.selection.start < 0 ? text.length : value.selection.start;
    final end = value.selection.end < 0 ? text.length : value.selection.end;
    final next = text.replaceRange(start, end, emoji);
    _text.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
    _onTyped(next);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final hardware = ChatPrefs.hardwareEnterSends(
      keyboardSends: _keyboardSends,
      platform: Theme.of(context).platform,
    );
    if (!hardware || event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    unawaited(_send());
    return KeyEventResult.handled;
  }

  bool get _mouseMenu =>
      kIsWeb || Plat.isWindows || Plat.isLinux || Plat.isMacOS;

  /// Double-tap hearts a plain message. Voice, photos, polls, links, and
  /// quotes keep their own taps, so they are left alone.
  bool _canHeartTap(ChatMessage message) {
    if (message.id <= 0 || message.replyText.isNotEmpty) return false;
    if (message.isVoice || message.isSong || message.isPhoto || message.isFile) {
      return false;
    }
    if (message.isPoll || message.isCard || message.isPlace || message.isCall) {
      return false;
    }
    if (message.links.isNotEmpty) return false;
    return message.text.trim().isNotEmpty;
  }

  /// One row of the long-press menu: icon + label, red for destructive.
  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label, {
    bool danger = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final color = danger ? scheme.error : scheme.onSurface;
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 20, color: danger ? scheme.error : scheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.md),
          Text(label, style: TextStyle(color: color)),
        ],
      ),
    );
  }

  Future<void> _openMessageMenu(ChatMessage message, Offset at) async {
    if (!mounted || message.id <= 0) return;
    unawaited(HapticFeedback.mediumImpact());
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final chosen = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(at.dx, at.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        const _ReactionMenuRow(),
        _menuItem('reply', Icons.reply_rounded, 'Reply'),
        if (message.text.trim().isNotEmpty)
          _menuItem('copy', Icons.copy_rounded, 'Copy'),
        if (_canEdit(message))
          _menuItem('edit', Icons.edit_outlined, 'Edit'),
        _menuItem('star', Icons.star_outline_rounded, 'Star'),
        _menuItem(
          'pin',
          _pinned.contains(message.id) ? Icons.push_pin : Icons.push_pin_outlined,
          _pinned.contains(message.id) ? 'Unpin' : 'Pin',
        ),
        if (message.name == _me && _me.isNotEmpty)
          _menuItem('info', Icons.info_outline_rounded, 'Info'),
        if (chatCanForward(message))
          _menuItem('forward', Icons.forward_rounded, 'Forward'),
        if (message.links.isNotEmpty)
          _menuItem('link', Icons.download_rounded, 'Save link'),
        _menuItem(
          'select',
          Icons.check_circle_outline_rounded,
          _selected.contains(message.id) ? 'Deselect' : 'Select',
        ),
        const PopupMenuDivider(),
        _menuItem('delete', Icons.delete_outline_rounded, 'Delete', danger: true),
        if (message.name == _me && _me.isNotEmpty)
          _menuItem('unsend', Icons.undo_rounded, 'Unsend', danger: true),
      ],
    );
    if (!mounted || chosen == null) return;
    if (chosen.startsWith('react:')) {
      await _react(message, chosen.substring(6));
      return;
    }
    switch (chosen) {
      case 'reply':
        setState(_selected.clear);
        _replyTo(message);
      case 'copy':
        final text = message.text.trim();
        if (text.isEmpty) return;
        await Clipboard.setData(ClipboardData(text: text));
        if (!mounted) return;
        AppSnack.info(context, 'Message copied');
      case 'edit':
        _beginEdit(message);
      case 'star':
        await _star(message);
      case 'pin':
        await _togglePin(message);
      case 'info':
        await _showInfo(message);
      case 'forward':
        await _forwardMany([message]);
      case 'link':
        setState(_selected.clear);
        _openLink(message.links.first);
      case 'select':
        _toggleSelect(message);
      case 'delete':
        setState(() {
          _selected
            ..clear()
            ..add(message.id);
        });
        await _deletePicked();
      case 'unsend':
        await _unsendOne(message);
    }
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
            padding: const EdgeInsets.only(right: AppSpacing.xs),
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
              tooltip: 'Star',
              onPressed: () => unawaited(_star(one)),
              icon: const Icon(Icons.star_outline_rounded),
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
          if (picked.any(chatCanForward))
            IconButton(
              tooltip: 'Forward',
              onPressed: () => unawaited(_forwardMany(picked)),
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
    if (message.isVoice || message.isSong || message.isPhoto || message.isFile) {
      return false;
    }
    if (message.isPoll || message.isCard || message.isPlace || message.isCall) {
      return false;
    }
    if (message.text.trim().isEmpty) return false;
    return DateTime.now().difference(message.at) < const Duration(hours: 24);
  }

  bool _sameName(String value) {
    final me = _me.replaceFirst(RegExp(r'^@'), '').trim().toLowerCase();
    final other = value.replaceFirst(RegExp(r'^@'), '').trim().toLowerCase();
    return me.isNotEmpty && me == other;
  }

  bool _canManageGroup(String owner, List<String> admins) {
    if (_me.isEmpty) return false;
    if (owner.isEmpty && admins.isEmpty) return true;
    if (_sameName(owner)) return true;
    return admins.any(_sameName);
  }

  Future<void> _sendPoll() async {
    final poll = await askChatPoll(context);
    if (poll == null || !mounted) return;
    try {
      final message = await _api.sendRich(_threadId, poll: poll);
      if (!mounted) return;
      _ingest(message);
    } catch (error) {
      if (!mounted) return;
      _chatProblem(chatErrorText(error));
    }
  }

  Future<void> _sendCard() async {
    final card = await askChatCard(context);
    if (card == null || !mounted) return;
    try {
      final message = await _api.sendRich(_threadId, card: card);
      if (!mounted) return;
      _ingest(message);
    } catch (error) {
      if (!mounted) return;
      _chatProblem(chatErrorText(error));
    }
  }

  Future<void> _sendPlace() async {
    final place = await askChatPlace(context);
    if (place == null || !mounted) return;
    try {
      final message = await _api.sendRich(_threadId, place: place);
      if (!mounted) return;
      _ingest(message);
    } catch (error) {
      if (!mounted) return;
      _chatProblem(chatErrorText(error));
    }
  }

  Future<void> _scheduleCurrent() async {
    var text = _text.text.trim();
    if (text.isEmpty) {
      final asked = await _askScheduleText();
      if (asked == null || asked.isEmpty || !mounted) return;
      text = asked;
    }
    final when = await askSendTime(context);
    if (when == null || !mounted) return;
    try {
      final status = _statusReply && _replyText.trim().isNotEmpty;
      final body = status ? statusReplyBody(_replyText, text) : text;
      await _api.scheduleMessage(
        _threadId,
        text: body,
        sendAt: when,
        reply: status ? 0 : (_replyId ?? 0),
      );
      if (!mounted) return;
      setState(() {
        _text.clear();
        _replyId = null;
        _replyName = '';
        _replyText = '';
        _statusReply = false;
        _error = null;
      });
      AppSnack.info(context, 'Message scheduled');
    } catch (error) {
      if (!mounted) return;
      _chatProblem(chatErrorText(error));
    }
  }

  Future<String?> _askScheduleText() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Schedule a message'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Message'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Next'),
            ),
          ],
        );
      },
    ).whenComplete(controller.dispose);
  }

  Future<void> _setVanish() async {
    final seconds = await askVanish(context);
    if (seconds == null || !mounted) return;
    try {
      await _api.setTimer(_threadId, vanish: seconds);
      if (!mounted) return;
      setState(() => _vanish = seconds);
    } catch (error) {
      if (!mounted) return;
      _chatProblem(chatErrorText(error));
    }
  }

  Future<void> _setNotify() async {
    final mode = await askNotifyMode(
      context,
      group: _isGroup,
      current: ChatPrefs.modeFor(_threadId),
    );
    if (mode == null) return;
    await ChatPrefs.setNotify(_threadId, mode);
  }

  Future<void> _vote(ChatMessage message, int? choice, bool close) async {
    try {
      final updated = await _api.votePoll(
        _threadId,
        message.id,
        choice: choice,
        close: close,
      );
      if (!mounted) return;
      _ingest(updated);
    } catch (error) {
      if (!mounted) return;
      _chatProblem(chatErrorText(error));
    }
  }

  Future<void> _acceptRequest() async {
    try {
      await _api.acceptRequest(_threadId);
      if (!mounted) return;
      setState(() => _request = false);
    } catch (error) {
      if (!mounted) return;
      _chatProblem(chatErrorText(error));
    }
  }

  Future<void> _react(ChatMessage message, String emoji) async {
    unawaited(HapticFeedback.selectionClick());
    setState(_selected.clear);
    try {
      final updated = await _api.react(_threadId, message.id, emoji);
      if (!mounted) return;
      _ingest(updated);
    } catch (error) {
      if (!mounted) return;
      _chatProblem(chatErrorText(error));
    }
  }

  void _beginEdit(ChatMessage message) {
    setState(() {
      _selected.clear();
      _editingId = message.id;
      _replyId = null;
      _replyName = '';
      _replyText = '';
      _statusReply = false;
      _text.text = message.text;
      _text.selection = TextSelection.collapsed(offset: _text.text.length);
    });
    _focus.requestFocus();
  }

  Future<void> _star(ChatMessage message) async {
    setState(_selected.clear);
    try {
      await _api.setStar(_threadId, message.id, on: true);
      if (!mounted) return;
      AppSnack.success(context, 'Saved to starred messages');
    } catch (error) {
      if (!mounted) return;
      _chatProblem(chatErrorText(error));
    }
  }

  Future<void> _togglePin(ChatMessage message) async {
    setState(_selected.clear);
    try {
      final pinned = await _api.pin(_threadId, message.id);
      if (!mounted) return;
      setState(() => _pinned = pinned);
    } catch (error) {
      if (!mounted) return;
      _chatProblem(chatErrorText(error));
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
        if (_isGroup)
          info.readers.isEmpty
              ? 'No one else has read this'
              : 'Read by\n${info.readers.map((reader) => reader.name).join('\n')}',
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
      _chatProblem(chatErrorText(error));
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
    AppSnack.info(context, 'Message copied');
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
      _chatProblem(chatErrorText(error));
      return;
    }
    _drop(message.id);
    if (mounted) setState(_selected.clear);
  }

  Future<void> _forwardMany(List<ChatMessage> messages) async {
    final texts = [
      for (final message in messages)
        if (chatCanForward(message)) message.text.trim(),
    ];
    if (texts.isEmpty) return;
    final List<ChatThreadSummary> threads;
    try {
      threads = await _api.threads();
    } catch (error) {
      if (!mounted) return;
      _chatProblem(chatErrorText(error));
      return;
    }
    if (!mounted) return;
    final others = [
      for (final item in threads)
        if (item.id != _threadId) item,
    ];
    if (others.isEmpty) {
      _chatProblem('There is no other chat to forward to.');
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
      for (final text in texts) {
        await _api.send(target.id, text);
      }
    } catch (error) {
      if (!mounted) return;
      _chatProblem(chatErrorText(error));
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
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
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
    final subtitle = groupLine;
    final body = Column(
      children: [
        AppBar(
          toolbarHeight: 64,
          elevation: 0,
          scrolledUnderElevation: 0,
          backgroundColor: canvas,
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
            if (!selecting &&
                !_isGroup &&
                !_searching &&
                callsOnThisDevice(windows: Plat.isWindows))
              IconButton(
                tooltip: 'Audio call',
                onPressed: () => unawaited(
                  ChatCalls.instance.start(_threadId, title),
                ),
                icon: const Icon(Icons.call_rounded),
              ),
            if (!selecting)
              IconButton(
                tooltip: _searching ? 'Close search' : 'Search',
                onPressed: () => setState(() {
                  _searching = !_searching;
                  if (!_searching) {
                    _search.clear();
                    _searchCursor = 0;
                  }
                }),
                icon: Icon(
                  _searching ? Icons.close_rounded : Icons.search_rounded,
                ),
              ),
            if (!selecting && !_searching)
              PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (value) {
                  if (value == 'media') {
                    _openMedia(title);
                  } else if (value == 'wall') {
                    unawaited(_pickWallpaper());
                  } else if (value == 'search') {
                    setState(() => _searching = true);
                  } else if (value == 'mute') {
                    unawaited(_toggleMute());
                  } else if (value == 'vanish') {
                    unawaited(_setVanish());
                  } else if (value == 'block') {
                    unawaited(_confirmBlock(title));
                  }
                },
                itemBuilder: (context) => [
                  _menuItem('search', Icons.search_rounded, 'Search'),
                  _menuItem('media', Icons.perm_media_outlined, 'Media'),
                  _menuItem(
                    'mute',
                    ChatInboxFilter.isMuted(_threadId)
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_off_outlined,
                    ChatInboxFilter.isMuted(_threadId) ? 'Unmute' : 'Mute',
                  ),
                  _menuItem(
                    'vanish',
                    Icons.timer_outlined,
                    _vanish > 0 ? 'Disappearing messages: on' : 'Disappearing messages',
                  ),
                  _menuItem('wall', Icons.wallpaper_rounded, 'Wallpaper'),
                  if (!_isGroup) ...[
                    const PopupMenuDivider(),
                    _menuItem(
                      'block',
                      Icons.block_rounded,
                      _blocked ? 'Unblock' : 'Block',
                      danger: !_blocked,
                    ),
                  ],
                ],
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
                  onChanged: _onSearchChanged,
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
                const SizedBox(width: AppSpacing.md),
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
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2,
                        ),
                      ),
                      _ActivitySlot(
                        tick: _activityTick,
                        threadId: _threadId,
                        builder: (recording) => ChatActivityLine(recording: recording),
                        idle: ValueListenableBuilder<bool>(
                          valueListenable: ChatLive.instance.connected,
                          builder: (context, connected, _) {
                            if (!connected) {
                              return Text(
                                'Connecting',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: scheme.onSurfaceVariant,
                                ),
                              );
                            }
                            if (subtitle.isEmpty) return const SizedBox.shrink();
                            return Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: _peerOnline
                                    ? ChatUiTokens.brand
                                    : scheme.onSurfaceVariant,
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_searching)
          Material(
            color: canvas,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 12, 4),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Previous',
                    onPressed: _searchHits.isEmpty ? null : () => _moveSearch(-1),
                    icon: const Icon(Icons.keyboard_arrow_up_rounded),
                  ),
                  IconButton(
                    tooltip: 'Next',
                    onPressed: _searchHits.isEmpty ? null : () => _moveSearch(1),
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  ),
                  Expanded(
                    child: Text(
                      _searchLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
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
                    pattern: _wallPattern,
                    image: _wallImage,
                  ),
                ),
                if (_pinned.isNotEmpty && !_searching)
                  Positioned(
                    top: 8,
                    left: 12,
                    right: 12,
                    child: Material(
                      color: scheme.brightness == Brightness.dark
                          ? ChatUiTokens.fieldDark
                          : Colors.white,
                      elevation: 0,
                      borderRadius: AppRadii.lgAll,
                      child: ListTile(
                        dense: true,
                        minTileHeight: 48,
                        leading: const Icon(
                          Icons.push_pin_rounded,
                          color: ChatUiTokens.brand,
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
                    child: SingleChildScrollView(
                      child: EmptyState(
                        icon: Icons.chat_bubble_outline_rounded,
                        title: _searching ? 'No matches' : 'No messages yet',
                        message: _searching
                            ? 'Try a different word.'
                            : 'Say hello, or paste a public link. Tap a link to save it.',
                        action: _searching || _blocked
                            ? null
                            : ActionChip(
                                key: const ValueKey('chat-say-hi'),
                                avatar: const Icon(Icons.waving_hand_outlined, size: 18),
                                label: const Text('Say hi 👋'),
                                onPressed: _sayHi,
                              ),
                      ),
                    ),
                  )
                else
                  Builder(
                    builder: (context) {
                      final rows = _rows();
                      final more = _window < _shown.length;
                      // Reversed: the newest message is built first at the
                      // bottom, so the chat opens on it with no jump.
                      return ListView.builder(
                        controller: _scroll,
                        reverse: true,
                        padding: EdgeInsets.fromLTRB(
                          12,
                          _pinned.isNotEmpty && !_searching ? 72 : 12,
                          12,
                          12,
                        ),
                        itemCount: rows.length + (more ? 1 : 0),
                        itemBuilder: (context, slot) {
                          if (slot >= rows.length) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                              child: Center(
                                child: SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            );
                          }
                          final index = rows.length - 1 - slot;
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
                          // Each bubble paints on its own layer, so selection,
                          // swipe-to-reply and list scrolling reuse its picture.
                          final tick = chatTick(
                            mine: mine,
                            id: message.id,
                            peerDelivered: _peerDelivered,
                            peerRead: _peerRead,
                            status: message.status,
                          );
                          Widget bubble = RepaintBoundary(
                            child: Semantics(
                            container: true,
                            label: chatBubbleSemantics(
                              mine: mine,
                              sender: message.name,
                              time: TimeOfDay.fromDateTime(message.at.toLocal()).format(context),
                              tick: tick,
                              voice: message.isVoice,
                              voiceMs: message.voiceMs,
                              photo: message.isPhoto,
                              file: message.isFile,
                              song: message.isSong,
                              poll: message.isPoll,
                              edited: message.isEdited,
                            ),
                            child: ChatBubble(
                            key: _keyFor(message.id),
                            message: message,
                            threadId: _threadId,
                            mine: mine,
                            tail: tail,
                            tight: tight,
                            api: _api,
                            tick: tick,
                            me: _me,
                            onPoll: (choice, close) =>
                                unawaited(_vote(message, choice, close)),
                            onLink: _openLink,
                            onUsername: (name) => unawaited(
                              openUsernameChat(
                                context,
                                name,
                                currentThreadId: _threadId,
                              ),
                            ),
                            onQuote: _onQuote,
                            highlight: _searching ? _search.text.trim() : '',
                            flash: message.id == _flashId || _isSearchHit(message.id),
                            album: message.isPhoto
                                ? chatPhotoAlbum(_messages, message)
                                : const [],
                            onOpenFile: message.isFile
                                ? () => unawaited(_openAttachment(message))
                                : null,
                            onReactions: message.reactions.isEmpty
                                ? null
                                : () => _showReactions(message),
                            onRetry: message.status == 'failed' || message.status == 'queued'
                                ? () => unawaited(_retry(message))
                                : null,
                            onLongPress: (details) {
                              if (_mouseMenu) {
                                _openMessageMenu(message, details.globalPosition);
                              } else {
                                _toggleSelect(message);
                              }
                            },
                            onSecondaryTap: (at) => _openMessageMenu(message, at),
                            onDoubleTap: _canHeartTap(message)
                                ? () => unawaited(_react(message, '❤️'))
                                : null,
                            ),
                            ),
                          );
                          if (_mouseMenu && message.id > 0) {
                            bubble = _MouseMessageBar(
                              mine: mine,
                              onReact: (emoji) => unawaited(_react(message, emoji)),
                              onMenu: (at) => _openMessageMenu(message, at),
                              child: bubble,
                            );
                          }
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
                          if (_mouseMenu) {
                            if (!selecting) return bubble;
                            return GestureDetector(
                              onTap: () => _toggleSelect(message),
                              behavior: HitTestBehavior.opaque,
                              child: AbsorbPointer(
                                child: SizedBox(width: double.infinity, child: bubble),
                              ),
                            );
                          }
                          final replyRow = ChatSwipeReply(
                            onReply: () => _replyTo(message),
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
        ColoredBox(
          color: canvas,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ActivitySlot(
                    tick: _activityTick,
                    threadId: _threadId,
                    builder: (recording) => Padding(
                      padding: const EdgeInsets.only(left: 14, bottom: AppSpacing.xs),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: ChatActivityLine(recording: recording),
                      ),
                    ),
                  ),
                  if (_editingId != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                      decoration: BoxDecoration(
                        color: scheme.brightness == Brightness.dark
                            ? ChatUiTokens.fieldDark
                            : Colors.white,
                        borderRadius: AppRadii.mdAll,
                        border: const Border(
                          left: BorderSide(color: ChatUiTokens.brand, width: 3),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Editing',
                              style: TextStyle(
                                color: ChatUiTokens.brand,
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
                  if (_request && !_isGroup)
                    Container(
                      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                      decoration: BoxDecoration(
                        color: scheme.brightness == Brightness.dark
                            ? ChatUiTokens.fieldDark
                            : Colors.white,
                        borderRadius: AppRadii.mdAll,
                      ),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Message request. Accept to answer, or leave it until you reply.',
                            ),
                          ),
                          TextButton(
                            onPressed: () => unawaited(_acceptRequest()),
                            child: const Text('Accept'),
                          ),
                        ],
                      ),
                    ),
                  if (_replyText.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                      decoration: BoxDecoration(
                        color: scheme.brightness == Brightness.dark
                            ? ChatUiTokens.fieldDark
                            : Colors.white,
                        borderRadius: AppRadii.mdAll,
                        border: const Border(
                          left: BorderSide(color: ChatUiTokens.brand, width: 3),
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
                                    color: ChatUiTokens.brand,
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
                              _statusReply = false;
                            }),
                            icon: const Icon(Icons.close_rounded, size: 20),
                          ),
                        ],
                      ),
                    ),
                  if (_voiceHint.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 14, bottom: AppSpacing.xs),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _voiceHint,
                          style: TextStyle(
                            color: _voiceCancel
                                ? scheme.error
                                : scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  if (_mentionQuery != null && _mentionChoices.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 160),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final name in _mentionChoices)
                            ListTile(
                              dense: true,
                              minTileHeight: 40,
                              title: Text('@$name'),
                              onTap: () => _insertMention(name),
                            ),
                        ],
                      ),
                    ),
                  if (_recording && (_voiceLocked || !_voiceHolding))
                    ChatRecordingBar(
                      view: _recorder.view,
                      onDelete: () => unawaited(_finishVoice(send: false)),
                      onSend: () => unawaited(_finishVoice(send: true)),
                      onPause: () => unawaited(_recorder.togglePause()),
                    )
                  else ...[
                    if (_emojiOpen)
                      EmojiPanel(onPick: _insertEmoji),
                    ChatComposer(
                      controller: _text,
                      focusNode: _focus,
                      imeSends: _imeSends,
                      onKey: _onKey,
                      onChanged: _onTyped,
                      onSend: () => unawaited(_send()),
                      onMic: _onMicTap,
                      onMicHoldStart: Plat.isWeb ? null : _onMicHoldStart,
                      onMicHoldMove: Plat.isWeb ? null : _onMicHoldMove,
                      onMicHoldEnd: Plat.isWeb ? null : _onMicHoldEnd,
                      onAttach: () => unawaited(_attach()),
                      onEmoji: _toggleEmoji,
                      showMic: !Plat.isWeb,
                    ),
                  ],
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

  List<ChatMessage> get _shown => _messages;

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

  Future<void> _toggleMute() async {
    final on = !ChatInboxFilter.isMuted(_threadId);
    try {
      await ChatInboxFilter.setMuted(_threadId, on: on);
      if (!mounted) return;
      setState(() {});
      AppSnack.info(context, on ? 'Chat muted' : 'Chat unmuted');
    } catch (error) {
      logQuiet('chat_thread.mute', error);
      _chatProblem("Couldn't change notifications for this chat.");
    }
  }

  Future<void> _confirmBlock(String title) async {
    if (_blocked) {
      await _setBlocked(false);
      return;
    }
    final yes = await _confirm(
      'Block $title?',
      "They won't be able to message or call you. You can unblock them later.",
      'Block',
    );
    if (!yes || !mounted) return;
    await _setBlocked(true);
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
      _chatProblem(chatErrorText(error));
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
          about: group.about,
          rules: group.rules,
          announce: group.announce,
          owner: group.owner,
          admins: group.admins,
          canManage: _canManageGroup(group.owner, group.admins),
          onAdmin: (username, {required bool on}) {
            return _api.setGroupAdmin(_threadId, username, on: on);
          },
          onRemove: (username) async {
            await _api.removeMember(_threadId, username);
            if (mounted) {
              setState(() {
                _members = [
                  for (final name in _members)
                    if (name != username) name,
                ];
              });
            }
          },
          onTransfer: (username) async {
            await _api.transferGroup(_threadId, username);
            if (mounted) setState(() => _owner = username);
          },
          onInvite: (hours) => _api.rotateInvite(_threadId, hours: hours),
          onInfo: ({String? about, String? rules, bool? announce}) async {
            await _api.setGroupInfo(
              _threadId,
              about: about,
              rules: rules,
              announce: announce,
            );
            if (!mounted) return;
            setState(() {
              if (about != null) _about = about;
              if (rules != null) _rules = rules;
              if (announce != null) _announce = announce;
            });
          },
          onMedia: () => _openMedia(title),
        );
      } catch (error) {
        if (!mounted) return;
        _chatProblem(chatErrorText(error));
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
      onMedia: () => _openMedia(title),
    );
  }

  void _openMedia(String title) {
    final label = title.trim().isEmpty ? 'Media' : title.trim();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ChatMediaPage(
          title: label,
          messages: _messages,
          onLink: (url) {
            if (!mounted) return;
            _openLink(url);
          },
        ),
      ),
    );
  }

  void _showReactions(ChatMessage message) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final reaction in message.reactions)
                ListTile(
                  leading: Text(
                    reaction.emoji,
                    style: const TextStyle(fontSize: 22),
                  ),
                  title: Text(
                    reaction.user.trim().isEmpty ? 'Someone' : reaction.user.trim(),
                  ),
                  minTileHeight: 48,
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickWallpaper() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('App default'),
                minTileHeight: 48,
                onTap: () => Navigator.pop(context, ChatWalls.modeDefault),
              ),
              ListTile(
                title: const Text('Pattern'),
                minTileHeight: 48,
                onTap: () => Navigator.pop(context, ChatWalls.modePattern),
              ),
              ListTile(
                title: const Text('Plain'),
                minTileHeight: 48,
                onTap: () => Navigator.pop(context, ChatWalls.modePlain),
              ),
              ListTile(
                title: const Text('Photo'),
                minTileHeight: 48,
                onTap: () => Navigator.pop(context, ChatWalls.modePhoto),
              ),
            ],
          ),
        );
      },
    );
    if (choice == null || !mounted) return;
    if (choice == ChatWalls.modePhoto) {
      final picked = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Photos', extensions: ['jpg', 'jpeg', 'png']),
        ],
      );
      if (picked == null || !mounted) return;
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty || !mounted) return;
      await ChatWalls.savePhoto(_threadId, bytes);
      if (!mounted) return;
      setState(() {
        _wallMode = ChatWalls.modePhoto;
        _wallBytes = bytes;
      });
      return;
    }
    await ChatWalls.setMode(_threadId, choice);
    if (!mounted) return;
    setState(() {
      _wallMode = choice;
      if (choice != ChatWalls.modePhoto) _wallBytes = null;
    });
  }

  List<_Row> _rows() {
    final rows = <_Row>[];
    DateTime? previous;
    final now = DateTime.now();
    final shown = _shown;
    final hidden = chatPhotoFollowers(shown);
    var markedNew = false;
    var newCount = 0;
    for (final message in shown) {
      if (hidden.contains(message.id)) continue;
      if (message.name != _me && message.id > _seenAtOpen) newCount++;
    }
    final start = (shown.length - _window).clamp(0, shown.length);
    for (final message in shown.skip(start)) {
      if (hidden.contains(message.id)) continue;
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

/// The "typing…" / "recording…" line. Rebuilds on its own when the peer's
/// activity changes; shows [idle] (or nothing) otherwise.
class _ActivitySlot extends StatelessWidget {
  const _ActivitySlot({
    required this.tick,
    required this.threadId,
    required this.builder,
    this.idle,
  });

  final ValueListenable<int> tick;
  final String threadId;
  final Widget Function(bool recording) builder;
  final Widget? idle;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: tick,
      builder: (context, value, child) {
        final recording = ChatLive.isRecording(threadId);
        final peerTyping = !recording && ChatLive.isTyping(threadId);
        if (recording || peerTyping) return builder(recording);
        return idle ?? const SizedBox.shrink();
      },
    );
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
                color: ChatUiTokens.brand,
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

/// The six reactions at the top of the message menu. A normal menu item would
/// take the tap itself and close without an emoji.
class _ReactionMenuRow extends PopupMenuEntry<String> {
  const _ReactionMenuRow();

  static const emojis = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

  @override
  double get height => 48;

  @override
  bool represents(String? value) => value != null && value.startsWith('react:');

  @override
  State<_ReactionMenuRow> createState() => _ReactionMenuRowState();
}

class _ReactionMenuRowState extends State<_ReactionMenuRow> {
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (final emoji in _ReactionMenuRow.emojis)
          InkWell(
            onTap: () => Navigator.pop(context, 'react:$emoji'),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: AppSpacing.sm),
              child: Text(emoji, style: const TextStyle(fontSize: 22)),
            ),
          ),
      ],
    );
  }
}

/// Reactions and the rest of the message menu, shown when the pointer rests
/// on a message. A mouse has no long press, so this is how a computer reacts.
class _MouseMessageBar extends StatefulWidget {
  const _MouseMessageBar({
    required this.mine,
    required this.onReact,
    required this.onMenu,
    required this.child,
  });

  final bool mine;
  final ValueChanged<String> onReact;
  final ValueChanged<Offset> onMenu;
  final Widget child;

  @override
  State<_MouseMessageBar> createState() => _MouseMessageBarState();
}

class _MouseMessageBarState extends State<_MouseMessageBar> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final dark = ChatUiTokens.dark(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _open = true),
      onExit: (_) => setState(() => _open = false),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: widget.mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          widget.child,
          if (_open)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xxs),
              child: Material(
                elevation: 2,
                color: ChatUiTokens.field(dark),
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final emoji in const ['👍', '❤️', '😂', '😮', '😢', '🙏'])
                        InkWell(
                          onTap: () => widget.onReact(emoji),
                          borderRadius: AppRadii.lgAll,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: AppSpacing.xs),
                            child: Text(emoji, style: const TextStyle(fontSize: 18)),
                          ),
                        ),
                      IconButton(
                        tooltip: 'More',
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          final box = context.findRenderObject() as RenderBox?;
                          final at = box == null
                              ? Offset.zero
                              : box.localToGlobal(box.size.center(Offset.zero));
                          widget.onMenu(at);
                        },
                        icon: const Icon(Icons.more_horiz_rounded, size: 18),
                      ),
                    ],
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
    this.onUsername,
    this.me = '',
    this.onPoll,
    this.tail = true,
    this.tight = false,
    this.onQuote,
    this.onRetry,
    this.onSecondaryTap,
    this.onDoubleTap,
    this.album = const [],
    this.highlight = '',
    this.flash = false,
    this.onOpenFile,
    this.onReactions,
  });

  final ChatMessage message;
  final String threadId;
  final bool mine;
  final bool tail;
  final bool tight;
  final ChatApi api;
  final String tick;
  final ValueChanged<String> onLink;
  final ValueChanged<String>? onUsername;
  final ValueChanged<int>? onQuote;
  final ValueChanged<LongPressStartDetails>? onLongPress;
  final ValueChanged<Offset>? onSecondaryTap;
  final VoidCallback? onDoubleTap;
  final String me;
  final void Function(int? choice, bool close)? onPoll;
  final VoidCallback? onRetry;
  final List<ChatMessage> album;
  final String highlight;
  final bool flash;
  final VoidCallback? onOpenFile;
  final VoidCallback? onReactions;

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
                  linkColor: link,
                  onUsername: onUsername,
                  highlight: highlight,
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
          final statusParts = message.isVoice ||
                  message.isPhoto ||
                  message.isSong ||
                  message.isFile ||
                  message.isPoll ||
                  message.card != null ||
                  message.place != null ||
                  message.isCall
              ? null
              : parseStatusReply(caption);
          final barePhoto =
              message.isPhoto && (caption.isEmpty || caption == 'Photo');
          final bareEmoji = quote == null &&
              !message.isVoice &&
              !message.isPhoto &&
              !message.isSong &&
              !message.isFile &&
              !message.isPoll &&
              message.card == null &&
              message.place == null &&
              !message.isCall &&
              message.links.isEmpty &&
              emojiOnlyText(caption);
          final Widget body;
          if (bareEmoji) {
            body = Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  caption,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: emojiOnlySize(emojiClusterCount(caption)),
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: AppSpacing.xxs),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: dark ? const Color(0x66000000) : const Color(0xCCFFFFFF),
                    borderRadius: AppRadii.smAll,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(6, 1, 4, 1),
                    child: _stamp(
                      time,
                      dark ? Colors.white : ChatUiTokens.timeLight,
                      tick,
                      tickColor: tick == 'read'
                          ? ChatUiTokens.linkDark
                          : (dark ? Colors.white70 : ChatUiTokens.timeLight),
                      onRetry: onRetry,
                      edited: message.isEdited,
                    ),
                  ),
                ),
              ],
            );
          } else if (message.isVoice) {
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
            final photos = album.length > 1 ? album : <ChatMessage>[message];
            final wide = photos.length > 1;
            final photoWidth = wide
                ? ((max - 16) > 280 ? 280.0 : (max - 16))
                : cardWidth;
            final overlayTick = tick == 'read'
                ? ChatUiTokens.linkDark
                : Colors.white;
            final Widget picture;
            if (!wide) {
              picture = _ChatPicture(message: message, threadId: threadId);
            } else {
              final cell = ((photoWidth - 2) / 2).clamp(40.0, 140.0).toDouble();
              picture = Wrap(
                spacing: 2,
                runSpacing: 2,
                children: [
                  for (final item in photos)
                    SizedBox(
                      width: cell,
                      child: _ChatPicture(message: item, threadId: threadId),
                    ),
                ],
              );
            }
            body = SizedBox(
              width: photoWidth < 0 ? 0.0 : photoWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ?quote,
                  Stack(
                    children: [
                      picture,
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
                    const SizedBox(height: AppSpacing.xs),
                    _TimedLine(
                      text: ChatTapText(
                        text: message.text,
                        links: message.links,
                        color: fg,
                        linkColor: link,
                        onLink: onLink,
                        onUsername: onUsername,
                        reserve: reserve,
                        highlight: highlight,
                      ),
                      stamp: stamp,
                    ),
                  ],
                ],
              ),
            );
          } else if (message.isFile) {
            final captionText = message.text.trim();
            final showCaption = captionText.isNotEmpty && captionText != message.fileName.trim();
            body = SizedBox(
              width: cardWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ?quote,
                  ChatFileCard(
                    message: message,
                    onOpen: () => onOpenFile?.call(),
                  ),
                  if (showCaption)
                    _TimedLine(
                      text: ChatTapText(
                        text: message.text,
                        links: message.links,
                        color: fg,
                        linkColor: link,
                        onLink: onLink,
                        onUsername: onUsername,
                        reserve: reserve,
                        highlight: highlight,
                      ),
                      stamp: stamp,
                    )
                  else
                    stamp,
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
          } else if (message.isPoll) {
            body = SizedBox(
              width: cardWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ?quote,
                  ChatPollView(
                    message: message,
                    me: me,
                    onVote: (choice, close) => onPoll?.call(choice, close),
                  ),
                  stamp,
                ],
              ),
            );
          } else if (message.card != null) {
            body = SizedBox(
              width: cardWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ?quote,
                  ChatCardView(card: message.card!),
                  stamp,
                ],
              ),
            );
          } else if (message.place != null) {
            body = SizedBox(
              width: cardWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ?quote,
                  ChatPlaceView(place: message.place!, onOpen: onLink),
                  stamp,
                ],
              ),
            );
          } else if (message.isCall) {
            final length = message.callMs <= 0
                ? ''
                : ' ${message.callMs ~/ 60}:${(message.callMs % 60).toString().padLeft(2, '0')}';
            body = IntrinsicWidth(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ?quote,
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.call_rounded, size: 18),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          message.text.trim().isEmpty
                              ? 'Audio call$length'
                              : '${message.text}$length',
                        ),
                      ),
                    ],
                  ),
                  stamp,
                ],
              ),
            );
          } else if (statusParts != null) {
            final reply = statusParts.reply;
            final emoji = reply.isNotEmpty && emojiOnlyText(reply);
            final openStatus = statusParts.id.isEmpty
                ? null
                : () => unawaited(openQuotedStatus(context, statusParts.id));
            body = IntrinsicWidth(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StatusQuote(
                    snippet: statusParts.snippet,
                    dark: dark,
                    linkColor: link,
                    onUsername: onUsername,
                    highlight: highlight,
                    photo: statusParts.photo,
                    statusId: statusParts.id,
                    onTap: openStatus,
                  ),
                  if (reply.isEmpty)
                    stamp
                  else
                    _TimedLine(
                      text: emoji
                          ? Text(
                              reply,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: emojiOnlySize(emojiClusterCount(reply)),
                                height: 1.15,
                              ),
                            )
                          : ChatTapText(
                              text: reply,
                              links: message.links,
                              color: fg,
                              linkColor: link,
                              onLink: onLink,
                              onUsername: onUsername,
                              reserve: reserve,
                              highlight: highlight,
                            ),
                      stamp: stamp,
                    ),
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
                    text: ChatTapText(
                      text: message.text,
                      links: message.links,
                      color: fg,
                      linkColor: link,
                      onLink: onLink,
                      onUsername: onUsername,
                      reserve: reserve,
                      highlight: highlight,
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
                    text: ChatTapText(
                      text: message.text,
                      links: message.links,
                      color: fg,
                      linkColor: link,
                      onLink: onLink,
                      onUsername: onUsername,
                      reserve: reserve,
                      highlight: highlight,
                    ),
                    stamp: stamp,
                  ),
                ],
              ),
            );
          }
          final radius = BorderRadius.only(
            topLeft: Radius.circular(tight && !mine ? 6 : 18),
            topRight: Radius.circular(tight && mine ? 6 : 18),
            bottomLeft: Radius.circular(
              tail && !mine ? 2 : (tight && !mine ? 6 : 18),
            ),
            bottomRight: Radius.circular(
              tail && mine ? 2 : (tight && mine ? 6 : 18),
            ),
          );
          final hasReactions = message.reactions.isNotEmpty;
          final bubbleColor = flash
              ? Color.alphaBlend(const Color(0x66FFF59D), bg)
              : bg;
          return GestureDetector(
            onLongPressStart: onLongPress,
            onDoubleTap: onDoubleTap,
            onSecondaryTapDown: onSecondaryTap == null
                ? null
                : (details) => onSecondaryTap!(details.globalPosition),
            child: Padding(
              padding: EdgeInsets.only(
                top: tight ? 1 : 7,
                bottom: (tail ? 2 : 1) + (hasReactions ? 14 : 0),
                left: mine ? 0 : 8,
                right: mine ? 8 : 0,
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    constraints: BoxConstraints(maxWidth: max),
                    padding: bareEmoji
                        ? EdgeInsets.zero
                        : EdgeInsets.fromLTRB(
                            barePhoto ? 3 : 11,
                            barePhoto ? 3 : 7,
                            barePhoto ? 3 : 9,
                            barePhoto ? 3 : 5,
                          ),
                    decoration: BoxDecoration(
                      color: bareEmoji
                          ? (flash ? const Color(0xFFFFF59D) : Colors.transparent)
                          : bubbleColor,
                      borderRadius: bareEmoji ? BorderRadius.zero : radius,
                      boxShadow: bareEmoji || dark
                          ? null
                          : const [
                              BoxShadow(
                                color: Color(0x14000000),
                                blurRadius: 0.5,
                                offset: Offset(0, 1),
                              ),
                            ],
                    ),
                    child: body,
                  ),
                  if (tail && !bareEmoji)
                    Positioned(
                      right: mine ? -7 : null,
                      left: mine ? null : -7,
                      bottom: 0,
                      child: CustomPaint(
                        size: const Size(10, 12),
                        painter: _BubbleTail(color: bareEmoji ? bg : bubbleColor, mine: mine),
                      ),
                    ),
                  if (hasReactions)
                    Positioned(
                      left: mine ? 4 : null,
                      right: mine ? null : 4,
                      bottom: -12,
                      child: _ReactionBadge(
                        reactions: message.reactions,
                        dark: dark,
                        onTap: onReactions,
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

/// A small pill that sits on the corner of a message, outside the bubble.
class _ReactionBadge extends StatelessWidget {
  const _ReactionBadge({required this.reactions, required this.dark, this.onTap});

  final List<ChatReaction> reactions;
  final bool dark;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    for (final item in reactions) {
      if (item.emoji.isEmpty) continue;
      counts[item.emoji] = (counts[item.emoji] ?? 0) + 1;
    }
    if (counts.isEmpty) return const SizedBox.shrink();
    return GestureDetector(
      onTap: onTap,
      child: DecoratedBox(
      decoration: BoxDecoration(
        color: ChatUiTokens.field(dark),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: dark ? const Color(0xFF2A3942) : ChatUiTokens.lineLight,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 2,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: AppSpacing.xxs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in counts.entries) ...[
              Text(entry.key, style: const TextStyle(fontSize: 16, height: 1.1)),
              if (entry.value > 1) ...[
                const SizedBox(width: AppSpacing.xxs),
                Text(
                  '${entry.value}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: dark ? Colors.white70 : ChatUiTokens.timeLight,
                  ),
                ),
              ],
              if (entry.key != counts.keys.last) const SizedBox(width: AppSpacing.xs),
            ],
          ],
        ),
      ),
      ),
    );
  }
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
  } else if (tick == 'queued') {
    icon = Icons.cloud_off_rounded;
    size = 13;
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
      : (tick == 'failed' || tick == 'queued') && onRetry != null
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
        if (tick == 'queued') ...[
          Text(
            'Waiting for network',
            style: TextStyle(
              fontSize: 11,
              height: 1.1,
              color: timeColor,
              fontStyle: FontStyle.italic,
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
        ],
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
        if (icon != null) ...[const SizedBox(width: AppSpacing.xxs), mark],
      ],
    ),
  );
}

/// A status shown the way a replied message is, with the photo when it has one.
class _StatusQuote extends StatelessWidget {
  const _StatusQuote({
    required this.snippet,
    required this.dark,
    required this.linkColor,
    this.onUsername,
    this.highlight = '',
    this.photo = false,
    this.statusId = '',
    this.onTap,
  });

  final String snippet;
  final bool dark;
  final Color linkColor;
  final ValueChanged<String>? onUsername;
  final String highlight;
  final bool photo;
  final String statusId;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final words = snippet == 'Photo' ? '' : snippet;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.xs),
        padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
        decoration: BoxDecoration(
          color: ChatUiTokens.shadow(dark),
          borderRadius: AppRadii.smAll,
          border: const Border(
            left: BorderSide(color: ChatUiTokens.brand, width: 3),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Status',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: ChatUiTokens.brand,
                    ),
                  ),
                  if (words.isNotEmpty)
                    ChatTapText(
                      text: words,
                      color: ChatUiTokens.text(dark),
                      linkColor: linkColor,
                      onUsername: onUsername,
                      highlight: highlight,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: ChatUiTokens.text(dark),
                      ),
                    )
                  else if (!photo)
                    Text(
                      snippet,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: ChatUiTokens.text(dark),
                      ),
                    ),
                ],
              ),
            ),
            if (photo) ...[
              const SizedBox(width: AppSpacing.sm),
              _StatusThumb(id: statusId),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusThumb extends StatefulWidget {
  const _StatusThumb({required this.id});

  final String id;

  @override
  State<_StatusThumb> createState() => _StatusThumbState();
}

class _StatusThumbState extends State<_StatusThumb> {
  Uint8List? _bytes;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(_StatusThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      _bytes = null;
      _failed = false;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final id = widget.id.trim();
    if (id.isEmpty) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    try {
      final bytes = await ChatApi().statusImage(id);
      if (!mounted || id != widget.id) return;
      setState(() {
        _bytes = bytes;
        _failed = bytes == null || bytes.isEmpty;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return ClipRRect(
      borderRadius: AppRadii.smAll,
      child: SizedBox(
        width: 54,
        height: 72,
        child: bytes != null && bytes.isNotEmpty
            ? Image.memory(bytes, fit: BoxFit.cover)
            : ColoredBox(
                color: const Color(0x33000000),
                child: Icon(
                  _failed ? Icons.image_not_supported_outlined : Icons.image_outlined,
                  color: Colors.white70,
                  size: 22,
                ),
              ),
      ),
    );
  }
}

class _Quote extends StatelessWidget {
  const _Quote({
    required this.name,
    required this.text,
    required this.dark,
    required this.linkColor,
    this.onTap,
    this.onUsername,
    this.highlight = '',
  });

  final String name;
  final String text;
  final bool dark;
  final Color linkColor;
  final VoidCallback? onTap;
  final ValueChanged<String>? onUsername;
  final String highlight;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.xs),
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        decoration: BoxDecoration(
          color: ChatUiTokens.shadow(dark),
          borderRadius: BorderRadius.circular(6),
          border: const Border(
            left: BorderSide(color: ChatUiTokens.brand, width: 3),
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
                color: ChatUiTokens.brand,
              ),
            ),
            ChatTapText(
              text: text,
              color: ChatUiTokens.text(dark),
              linkColor: linkColor,
              onUsername: onUsername,
              highlight: highlight,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: ChatUiTokens.text(dark),
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
  bool _held = false;
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
    ChatPrefs.revision.addListener(_onPrefs);
    if (_bytes == null && ChatPrefs.dataSaver) {
      _held = true;
    } else if (_bytes == null) {
      _load();
    }
  }

  void _onPrefs() {
    if (!mounted || !_held || ChatPrefs.dataSaver || _bytes != null) return;
    setState(() => _held = false);
    _load();
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
    ChatPrefs.revision.removeListener(_onPrefs);
    super.dispose();
  }

  void _onStore() {
    if (_held || _bytes != null) return;
    _load();
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
        : bytes == null && _held
        ? GestureDetector(
            onTap: () {
              setState(() => _held = false);
              _load();
            },
            child: const SizedBox(
              height: 180,
              child: Center(child: Text('Tap to load this photo')),
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


