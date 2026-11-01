import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/features/chat/chat_alerts.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_drafts.dart';
import 'package:social_save/features/chat/chat_history.dart';
import 'package:social_save/features/chat/chat_live.dart';
import 'package:social_save/features/chat/chat_profile.dart';
import 'package:social_save/features/chat/chat_thread_screen.dart';
import 'package:social_save/features/chat/chat_ui.dart';
import 'package:social_save/shared/widgets/app_logo.dart';
import 'package:social_save/shared/widgets/page_layout.dart';

enum _ContactKind { phone, email }

/// Chats, in the shape of a messenger: a list, then a conversation.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final ChatApi _api = ChatApi();
  final TextEditingController _contact = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _find = TextEditingController();
  final FocusNode _findFocus = FocusNode();
  bool _showArchived = false;
  Timer? _poll;
  StreamSubscription<ChatLiveEvent>? _live;
  ChatUser? _user;
  List<ChatThreadSummary> _threads = const [];
  _ContactKind _kind = _ContactKind.phone;
  int _step = 0;
  String? _selectedId;
  String? _selectedName;
  String? _error;
  bool _booting = true;
  bool _signedIn = false;
  bool _busy = false;
  bool _refreshing = false;

  bool _wide(BuildContext context) => MediaQuery.sizeOf(context).width >= 840;

  void _onDrafts() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ChatDrafts.revision.addListener(_onDrafts);
    ChatInboxFilter.revision.addListener(_onDrafts);
    _live = ChatLive.instance.events.listen(_onLiveEvent);
    unawaited(ChatDrafts.ensure());
    unawaited(ChatInboxFilter.ensure());
    unawaited(_boot());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ChatDrafts.revision.removeListener(_onDrafts);
    ChatInboxFilter.revision.removeListener(_onDrafts);
    _live?.cancel();
    _poll?.cancel();
    _contact.dispose();
    _username.dispose();
    _find.dispose();
    _findFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_signedIn) return;
    if (state == AppLifecycleState.resumed) {
      _poll?.cancel();
      _poll = null;
      _startPoll();
      unawaited(_loadThreads());
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  Future<void> _boot() async {
    final token = await ChatSession.token();
    if (!mounted) return;
    if (token == null) {
      ChatAlerts.reset();
      setState(() {
        _signedIn = false;
        _user = null;
        _booting = false;
      });
      return;
    }
    final username = await ChatSession.username();
    final contact = await ChatSession.contact();
    final cached = username.isEmpty
        ? const <ChatThreadSummary>[]
        : await ChatHistory.threads(username);
    if (!mounted) return;
    setState(() {
      _signedIn = true;
      _error = null;
      if (username.isNotEmpty) {
        _user = _storedUser(username, contact);
        _threads = cached;
        _booting = false;
      } else {
        _booting = true;
      }
    });
    if (username.isNotEmpty) {
      ChatLive.instance.start();
      _startPoll();
    }
    try {
      final user = await _api.me();
      if (!mounted) return;
      await ChatSession.save(
        token: token,
        username: user.username,
        contact: user.contact,
      );
      if (!mounted) return;
      setState(() {
        _user = user;
        _booting = false;
      });
      ChatLive.instance.start();
      _startPoll();
      await _loadThreads();
    } catch (error) {
      if (!mounted) return;
      if (chatNeedsRegister(error)) {
        await ChatSession.clear();
        ChatAlerts.reset();
        if (!mounted) return;
        setState(() {
          _signedIn = false;
          _user = null;
          _booting = false;
          _error = null;
        });
        return;
      }
      if (_user != null) {
        setState(() => _booting = false);
        ChatLive.instance.start();
        _startPoll();
        return;
      }
      setState(() {
        _booting = false;
        _error = chatErrorText(error);
      });
    }
  }

  ChatUser _storedUser(String username, String contact) {
    final email = contact.contains('@');
    return ChatUser(
      id: '',
      username: username,
      phone: email ? '' : contact,
      email: email ? contact : '',
    );
  }

  void _startPoll() {
    _poll ??= Timer.periodic(const Duration(seconds: 12), (_) {
      if (!mounted || !_signedIn) return;
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;
      unawaited(_loadThreads());
    });
  }

  Future<void> _loadThreads() async {
    if (_refreshing || _user == null) return;
    _refreshing = true;
    try {
      final items = _mergeThreads(await _api.threads());
      if (!mounted) return;
      ChatAlerts.observe(
        items,
        me: _user!.username,
        notify: true,
        alert: (item, body) {
          final title = item.username.isEmpty ? 'New message' : item.username;
          chatAlertNow(
            threadId: item.id,
            title: title,
            body: body,
            username: item.username,
            photoRev: item.photoRev,
          );
        },
      );
      setState(() {
        _threads = items;
        _error = null;
      });
      final name = _user?.username ?? '';
      if (name.isNotEmpty) {
        unawaited(ChatHistory.archiveInbox(_api, name, items));
      }
    } catch (error) {
      if (!mounted) return;
      if (chatNeedsRegister(error)) {
        await ChatSession.clear();
        ChatAlerts.reset();
        if (!mounted) return;
        _poll?.cancel();
        _poll = null;
        setState(() {
          _signedIn = false;
          _user = null;
          _threads = const [];
          _error = null;
        });
        return;
      }
      setState(() {
        _error = _threads.isEmpty ? chatErrorText(error) : null;
      });
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _register() async {
    if (_busy) return;
    final username = _username.text.trim();
    final contact = _contact.text.trim();
    final problem = _registerProblem(contact, username);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final created = await _api.register(
        phone: _kind == _ContactKind.phone ? contact : '',
        email: _kind == _ContactKind.email ? contact : '',
        username: username,
      );
      await ChatSession.save(
        token: created.token,
        username: created.user.username,
        contact: created.user.contact,
      );
      if (!mounted) return;
      _contact.clear();
      _username.clear();
      setState(() {
        _user = created.user;
        _signedIn = true;
        _busy = false;
        _step = 0;
        _threads = const [];
      });
      ChatLive.instance.start();
      _startPoll();
      await _loadThreads();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = chatErrorText(error);
      });
    }
  }

  String? _registerProblem(String contact, String username) {
    if (_kind == _ContactKind.phone) {
      final digits = contact.replaceAll(RegExp(r'\D'), '');
      if (digits.length < 8 || digits.length > 15) {
        return 'Enter a phone number with the country code.';
      }
    } else {
      final email = contact.toLowerCase();
      final ok = RegExp(
        r'^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$',
      ).hasMatch(email);
      if (email.length > 80 || !ok) return 'Enter a valid email address.';
    }
    final name = username.toLowerCase().replaceFirst(RegExp(r'^@'), '');
    if (!RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(name)) {
      return 'Usernames are 3 to 20 letters, numbers, or underscores.';
    }
    return null;
  }

  void _nextStep() {
    final contact = _contact.text.trim();
    if (_kind == _ContactKind.phone) {
      final digits = contact.replaceAll(RegExp(r'\D'), '');
      if (digits.length < 8 || digits.length > 15) {
        setState(() => _error = 'Enter a phone number with the country code.');
        return;
      }
    } else {
      final email = contact.toLowerCase();
      final ok = RegExp(
        r'^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$',
      ).hasMatch(email);
      if (email.length > 80 || !ok) {
        setState(() => _error = 'Enter a valid email address.');
        return;
      }
    }
    setState(() {
      _step = 1;
      _error = null;
    });
  }

  Future<void> _openSaved(ChatThreadSummary item) async {
    if (_wide(context)) {
      setState(() {
        _selectedId = item.id;
        _selectedName = item.username;
      });
      return;
    }
    await context.push('/chat/${item.id}', extra: item.username);
    if (mounted) unawaited(_loadThreads());
  }

  Future<void> _openName(String raw) async {
    final name = raw.trim();
    if (name.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final opened = await _api.openThread(name);
      if (!mounted) return;
      _find.clear();
      setState(() {
        _busy = false;
        if (_wide(context)) {
          _selectedId = opened.id;
          _selectedName = opened.username;
        }
      });
      if (!_wide(context)) {
        await context.push('/chat/${opened.id}', extra: opened.username);
      }
      if (mounted) unawaited(_loadThreads());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = chatErrorText(error);
      });
    }
  }

  Future<void> _newChat() async {
    final controller = TextEditingController();
    final name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            4,
            20,
            16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'New chat',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                onSubmitted: (value) => Navigator.pop(context, value),
                decoration: const InputDecoration(
                  hintText: 'Username',
                  prefixText: '@',
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => Navigator.pop(context, controller.text),
                child: const Text('Message'),
              ),
            ],
          ),
        );
      },
    );
    controller.dispose();
    if (!mounted || name == null) return;
    await _openName(name);
  }

  void _onLiveEvent(ChatLiveEvent event) {
    if (!mounted) return;
    if (event.type == 'presence') {
      final name = event.from.trim().toLowerCase();
      if (name.isEmpty) return;
      setState(() {
        _threads = [
          for (final item in _threads)
            if (item.username.toLowerCase() == name)
              item.copyWith(
                online: event.on,
                lastSeen: event.at > 0
                    ? DateTime.fromMillisecondsSinceEpoch(event.at)
                    : item.lastSeen,
              )
            else
              item,
        ];
      });
      _keepThreads();
      return;
    }
    if (event.threadId.isEmpty) return;
    if (event.type == 'removed' && event.id > 0) {
      final me = _user?.username ?? '';
      if (me.isNotEmpty) unawaited(_applyRemoved(me, event.threadId, event.id));
      return;
    }
    if (event.type == 'message' && event.message != null) {
      final message = event.message!;
      if (message.id <= 0) return;
      final me = _user?.username ?? '';
      final open =
          event.threadId == ChatAlerts.openThread ||
          event.threadId == _selectedId;
      final incoming = me.isEmpty || message.name != me;
      final exists = _threads.any((item) => item.id == event.threadId);
      if (!exists) {
        if (!incoming || message.name.isEmpty) return;
        setState(() {
          _threads = [
            ChatThreadSummary(
              id: event.threadId,
              username: message.name,
              lastText: message.text,
              lastAt: message.at,
              lastId: message.id,
              lastFrom: message.name,
              lastStatus: message.status,
              unread: open ? 0 : 1,
            ),
            ..._threads,
          ];
        });
        _keepThreads();
        return;
      }
      _patchThread(event.threadId, (item) {
        if (message.id <= item.lastId) return item;
        return item.copyWith(
          lastText: message.text,
          lastAt: message.at,
          lastId: message.id,
          lastFrom: message.name,
          lastStatus: message.status.isEmpty ? item.lastStatus : message.status,
          unread: !incoming || open ? item.unread : item.unread + 1,
        );
      }, lift: true);
      return;
    }
    if (event.type == 'delivered' || event.type == 'read') {
      final me = _user?.username ?? '';
      _patchThread(event.threadId, (item) {
        if (me.isEmpty ||
            item.lastFrom != me ||
            event.id <= 0 ||
            item.lastId > event.id) {
          return item;
        }
        if (event.type == 'read') return item.copyWith(lastStatus: 'read');
        if (item.lastStatus == 'read') return item;
        return item.copyWith(lastStatus: 'delivered');
      });
    }
  }

  Future<void> _applyRemoved(String me, String threadId, int id) async {
    await ChatHistory.hide(username: me, threadId: threadId, ids: [id]);
    final stored = await ChatHistory.threads(me);
    if (!mounted) return;
    ChatThreadSummary? found;
    for (final item in stored) {
      if (item.id == threadId) found = item;
    }
    if (found == null) return;
    final row = found;
    setState(() {
      _threads = [
        for (final item in _threads)
          if (item.id == threadId) row.copyWith(online: item.online) else item,
      ];
    });
  }

  void _patchThread(
    String id,
    ChatThreadSummary Function(ChatThreadSummary item) patch, {
    bool lift = false,
  }) {
    ChatThreadSummary? next;
    final rest = <ChatThreadSummary>[];
    for (final item in _threads) {
      if (item.id == id) {
        next = patch(item);
      } else {
        rest.add(item);
      }
    }
    if (next == null || !mounted) return;
    final updated = next;
    setState(() {
      _threads = lift
          ? [updated, ...rest]
          : [
              for (final item in _threads)
                if (item.id == id) updated else item,
            ];
    });
    _keepThreads();
  }

  void _keepThreads() {
    final name = _user?.username ?? '';
    if (name.isEmpty) return;
    unawaited(ChatHistory.saveThreads(name, _threads));
  }

  List<ChatThreadSummary> _mergeThreads(List<ChatThreadSummary> items) {
    final local = {for (final item in _threads) item.id: item};
    return [for (final item in items) _preferThread(item, local[item.id])];
  }

  ChatThreadSummary _preferThread(
    ChatThreadSummary server,
    ChatThreadSummary? current,
  ) {
    if (current == null) return server;
    var next = server;
    if (current.lastId > server.lastId) {
      next = next.copyWith(
        lastText: current.lastText,
        lastAt: current.lastAt,
        lastId: current.lastId,
        lastFrom: current.lastFrom,
        lastStatus: current.lastStatus,
        unread: current.unread > server.unread ? current.unread : server.unread,
      );
    }
    final seen = current.lastSeen;
    if (seen != null &&
        (server.lastSeen == null || seen.isAfter(server.lastSeen!))) {
      next = next.copyWith(lastSeen: seen, online: current.online);
    }
    return next;
  }

  void _onRead(String id, int lastId) {
    setState(() {
      _threads = [
        for (final item in _threads)
          if (item.id == id)
            item.copyWith(
              lastId: item.lastId < lastId ? lastId : item.lastId,
              unread: 0,
            )
          else
            item,
      ];
    });
    _keepThreads();
  }

  @override
  Widget build(BuildContext context) {
    if (_booting) {
      return const Scaffold(
        body: _Waiting(
          text: 'Opening chats. The first open can take a moment.',
        ),
      );
    }
    if (!_signedIn) return _registerScaffold();
    if (_user == null) return _retryScaffold();
    final wide = _wide(context);
    final list = _inbox(wide);
    if (!wide) return list;
    return Scaffold(
      body: Row(
        children: [
          SizedBox(width: 380, child: list),
          const VerticalDivider(width: 1),
          Expanded(
            child: _selectedId == null
                ? const _EmptyPane()
                : ChatThreadView(
                    key: ValueKey(_selectedId),
                    threadId: _selectedId!,
                    username: _selectedName ?? '',
                    embedded: true,
                    onRead: _onRead,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _registerScaffold() {
    final scheme = Theme.of(context).colorScheme;
    final phone = _kind == _ContactKind.phone;
    final step = _step == 0;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: pagePadding(context, top: 28, bottom: 24, maxWidth: 460),
          children: [
            const Center(child: AppLogo(size: 72)),
            const SizedBox(height: 20),
            Text(
              step ? 'Enter your phone or email' : 'Choose your username',
              style: pageTitleStyle(context),
            ),
            const SizedBox(height: 8),
            Text(
              step
                  ? 'People will not see this. Social Save does not send a code. This device keeps the account.'
                  : 'This is the name people message. You cannot change it later.',
              style: TextStyle(
                fontSize: 14,
                height: 1.4,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            if (step) ...[
              SegmentedButton<_ContactKind>(
                segments: const [
                  ButtonSegment(
                    value: _ContactKind.phone,
                    label: Text('Phone'),
                  ),
                  ButtonSegment(
                    value: _ContactKind.email,
                    label: Text('Email'),
                  ),
                ],
                selected: {_kind},
                onSelectionChanged: _busy
                    ? null
                    : (next) => setState(() {
                        _kind = next.first;
                        _contact.clear();
                        _error = null;
                      }),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _contact,
                enabled: !_busy,
                autofocus: true,
                keyboardType: phone
                    ? TextInputType.phone
                    : TextInputType.emailAddress,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                onSubmitted: (_) => _nextStep(),
                decoration: InputDecoration(
                  labelText: phone ? 'Phone number' : 'Email',
                  hintText: phone ? '256700000111' : 'you@example.com',
                ),
              ),
            ] else
              TextField(
                controller: _username,
                enabled: !_busy,
                autofocus: true,
                autocorrect: false,
                maxLength: 20,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => unawaited(_register()),
                decoration: const InputDecoration(
                  labelText: 'Username',
                  hintText: 'ada',
                  prefixText: '@',
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: scheme.error, height: 1.35),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => step ? _nextStep() : unawaited(_register()),
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(step ? 'Next' : 'Done'),
            ),
            if (!step)
              TextButton(
                onPressed: _busy ? null : () => setState(() => _step = 0),
                child: const Text('Change phone or email'),
              ),
            if (_busy)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'The first open can take a moment.',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _retryScaffold() {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Chats')),
      body: ListView(
        padding: pagePadding(context, top: 24, bottom: 24),
        children: [
          Text(
            _error ?? 'Chat is not reachable right now.',
            style: TextStyle(color: scheme.error, height: 1.4),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => unawaited(_boot()),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }

  Future<void> _archiveThread(ChatThreadSummary item) {
    final on = !ChatInboxFilter.archived.contains(item.id);
    return ChatInboxFilter.setArchived(item.id, on: on);
  }

  Future<void> _muteThread(ChatThreadSummary item) async {
    final on = !ChatInboxFilter.isMuted(item.id);
    await ChatInboxFilter.setMuted(item.id, on: on);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(on ? 'Muted' : 'Unmuted')),
    );
  }

  Future<void> _hideThread(ChatThreadSummary item) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete chat'),
          content: const Text(
            'This removes the chat from this phone until a new message arrives. The other person still has it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (yes != true) return;
    if (_selectedId == item.id && mounted) {
      setState(() {
        _selectedId = null;
        _selectedName = null;
      });
    }
    await ChatInboxFilter.hide(item.id, item.lastId);
  }

  Widget _threadTile(ChatThreadSummary item, String me, bool wide) {
    final archived = ChatInboxFilter.archived.contains(item.id);
    return ChatListTile(
      key: ValueKey(item.id),
      item: item,
      me: me,
      selected: wide && item.id == _selectedId,
      muted: ChatInboxFilter.isMuted(item.id),
      archived: archived,
      avatar: GestureDetector(
        onTap: () => unawaited(
          showChatProfile(
            context,
            username: item.username,
            photoRev: item.photoRev,
            lastSeen: item.lastSeen,
            online: item.online,
          ),
        ),
        child: ChatFace(
          name: item.username,
          photoRev: item.photoRev,
          online: item.online,
          size: ChatUiTokens.avatar,
        ),
      ),
      onOpen: () => unawaited(_openSaved(item)),
      onArchive: () => unawaited(_archiveThread(item)),
      onMute: () => unawaited(_muteThread(item)),
      onDelete: () => unawaited(_hideThread(item)),
    );
  }

  Widget _inboxList(
    bool wide,
    ChatUser user,
    String query,
    bool canStart,
    List<ChatThreadSummary> shown,
    ColorScheme scheme,
  ) {
    final visible = [
      for (final item in shown)
        if (!ChatInboxFilter.hides(item.id, item.lastId)) item,
    ];
    final archived = [
      for (final item in visible)
        if (ChatInboxFilter.archived.contains(item.id)) item,
    ];
    final open = query.isEmpty
        ? [
            for (final item in visible)
              if (!ChatInboxFilter.archived.contains(item.id)) item,
          ]
        : visible;
    final showHeader = query.isEmpty && archived.isNotEmpty;
    final archivedShown = showHeader && _showArchived ? archived.length : 0;
    final empty = !canStart && open.isEmpty && !showHeader;
    final count =
        (canStart ? 1 : 0) +
        (showHeader ? 1 : 0) +
        archivedShown +
        open.length +
        (empty ? 1 : 0);
    return RefreshIndicator(
      onRefresh: _loadThreads,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: count,
        itemBuilder: (context, index) {
          var cursor = index;
          if (canStart) {
            if (cursor == 0) {
              return ListTile(
                leading: const Icon(Icons.person_add_alt_1_rounded),
                title: Text('Message @$query'),
                onTap: () => unawaited(_openName(query)),
              );
            }
            cursor--;
          }
          if (showHeader) {
            if (cursor == 0) {
              final unread = archived.fold<int>(
                0,
                (sum, item) => sum + item.unread,
              );
              return ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: const Text('Archived'),
                trailing: unread > 0
                    ? Text(
                        unread > 99 ? '99+' : '$unread',
                        style: const TextStyle(
                          color: ChatUiTokens.brand,
                          fontWeight: FontWeight.w800,
                        ),
                      )
                    : Icon(
                        _showArchived
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                      ),
                onTap: () => setState(() => _showArchived = !_showArchived),
              );
            }
            cursor--;
            if (_showArchived && cursor < archived.length) {
              return _threadTile(archived[cursor], user.username, wide);
            }
            if (_showArchived) cursor -= archived.length;
          }
          if (cursor < open.length) {
            return _threadTile(open[cursor], user.username, wide);
          }
          if (_threads.isEmpty) {
            return ChatEmptyInbox(onStart: () => _findFocus.requestFocus());
          }
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
            child: Text(
              'No chats match that search.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
            ),
          );
        },
      ),
    );
  }

  Widget _inbox(bool wide) {
    final scheme = Theme.of(context).colorScheme;
    final user = _user!;
    final query = _find.text.trim().toLowerCase().replaceFirst(
      RegExp(r'^@'),
      '',
    );
    final shown = [
      for (final item in _threads)
        if (query.isEmpty ||
            item.username.contains(query) ||
            item.lastText.toLowerCase().contains(query) ||
            ChatDrafts.peek(item.id).toLowerCase().contains(query))
          item,
    ];
    final canStart =
        query.isNotEmpty &&
        RegExp(r'^[a-z0-9_]{1,20}$').hasMatch(query) &&
        shown.every((item) => item.username != query);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            tooltip: 'Your profile',
            onPressed: () => unawaited(
              showChatProfile(
                context,
                username: user.username,
                contact: user.contact,
                photoRev: user.photoRev,
                onPhoto: (rev) {
                  final current = _user;
                  if (!mounted || current == null) return;
                  setState(() => _user = current.copyWith(photoRev: rev));
                },
              ),
            ),
            icon: ChatFace(
              name: user.username,
              size: 32,
              photoRev: user.photoRev,
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: 'chat-new',
        tooltip: 'New chat',
        onPressed: _busy ? null : () => unawaited(_newChat()),
        child: const Icon(Icons.chat_rounded),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: ChatSearchField(
              controller: _find,
              focusNode: _findFocus,
              onChanged: (_) => setState(() {}),
              onSubmitted: (value) => unawaited(_openName(value)),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                _error!,
                style: TextStyle(color: scheme.error, height: 1.35),
              ),
            ),
          Expanded(child: _inboxList(wide, user, query, canStart, shown, scheme)),
        ],
      ),
    );
  }
}

class _EmptyPane extends StatelessWidget {
  const _EmptyPane();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_rounded, size: 48, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            'Select a chat to start messaging',
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(height: 1.4, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
