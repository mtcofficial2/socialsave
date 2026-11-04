import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/features/chat/chat_admin_screen.dart';
import 'package:social_save/features/chat/chat_alerts.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_drafts.dart';
import 'package:social_save/features/chat/chat_history.dart';
import 'package:social_save/features/chat/chat_live.dart';
import 'package:social_save/features/chat/chat_profile.dart';
import 'package:social_save/features/chat/chat_thread_screen.dart';
import 'package:social_save/features/chat/chat_ui.dart';
import 'package:social_save/shared/widgets/app_logo.dart';
import 'package:social_save/shared/widgets/liquid_glass.dart';
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
  final TextEditingController _password = TextEditingController();
  bool _showPassword = false;
  final TextEditingController _find = TextEditingController();
  final FocusNode _findFocus = FocusNode();
  bool _showArchived = false;
  bool _showBlocked = false;
  bool _groups = false;
  Timer? _poll;
  StreamSubscription<ChatLiveEvent>? _live;
  ChatUser? _user;
  List<ChatThreadSummary> _threads = const [];
  _ContactKind _kind = _ContactKind.phone;
  int _step = 0;
  String? _selectedId;
  String? _selectedName;
  String _selectedSeen = '';
  bool _selectedGroup = false;
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
    _password.dispose();
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
      unawaited(ChatPresence.sync());
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
          chatAlertNow(
            threadId: item.id,
            title: item.label.trim().isEmpty ? 'New message' : item.label,
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
        password: _password.text,
      );
      await ChatSession.save(
        token: created.token,
        username: created.user.username,
        contact: created.user.contact,
      );
      unawaited(ChatPresence.sync());
      if (!mounted) return;
      _contact.clear();
      _username.clear();
      _password.clear();
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
    final password = _password.text;
    if (password.length < 6 || password.length > 64 || password.trim().isEmpty) {
      return 'Use a password of 6 to 64 characters.';
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
    final group = item.group || item.id.startsWith('g');
    final title = group ? item.label : item.name;
    final username = group ? '' : item.username;
    if (_wide(context)) {
      setState(() {
        _selectedId = item.id;
        _selectedName = username;
        _selectedSeen = title;
        _selectedGroup = group;
      });
      return;
    }
    await context.push(
      '/chat/${item.id}',
      extra: ChatThreadTarget(username: username, name: title, group: group),
    );
    if (mounted) unawaited(_loadThreads());
  }

  Future<void> _openName(String raw, {String? seenName}) async {
    final name = raw.trim();
    if (name.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final opened = await _api.openThread(name, seenName: seenName);
      if (!mounted) return;
      _find.clear();
      setState(() {
        _busy = false;
        if (_wide(context)) {
          _selectedId = opened.id;
          _selectedName = opened.username;
          _selectedSeen = opened.name;
          _selectedGroup = false;
        }
      });
      if (!_wide(context)) {
        await context.push(
          '/chat/${opened.id}',
          extra: ChatThreadTarget(username: opened.username, name: opened.name),
        );
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

  Future<String?> _askLine({
    required String title,
    required String label,
    required String action,
    int maxLength = 40,
    bool code = false,
  }) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: maxLength,
            textCapitalization: code
                ? TextCapitalization.characters
                : TextCapitalization.words,
            autocorrect: false,
            onSubmitted: (text) => Navigator.pop(context, text),
            decoration: InputDecoration(labelText: label),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: Text(action),
            ),
          ],
        );
      },
    );
    controller.dispose();
    final trimmed = value?.trim() ?? '';
    if (!mounted || trimmed.isEmpty) return null;
    return trimmed;
  }

  Future<void> _newGroup() async {
    setState(() => _groups = true);
    final name = await _askLine(
      title: 'New group',
      label: 'Group name',
      action: 'Create',
    );
    if (name == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final group = await _api.createGroup(name);
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Group code ${group.code}')),
      );
      await _openSaved(
        ChatThreadSummary(
          id: group.id,
          username: '',
          name: group.name,
          group: true,
          members: group.members.length,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = chatErrorText(error);
      });
    }
  }

  Future<void> _joinGroup() async {
    setState(() => _groups = true);
    final code = await _askLine(
      title: 'Join a group',
      label: '6-character code',
      action: 'Join',
      maxLength: 6,
      code: true,
    );
    if (code == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final group = await _api.joinGroup(code);
      if (!mounted) return;
      setState(() => _busy = false);
      await _openSaved(
        ChatThreadSummary(
          id: group.id,
          username: '',
          name: group.name,
          group: true,
          members: group.members.length,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = chatErrorText(error);
      });
    }
  }

  void _leftGroup(String id) {
    if (!mounted) return;
    setState(() {
      _threads = [for (final item in _threads) if (item.id != id) item];
      if (_selectedId == id) {
        _selectedId = null;
        _selectedName = null;
        _selectedSeen = '';
        _selectedGroup = false;
      }
    });
    unawaited(_loadThreads());
  }

  Future<void> _newChat() async {
    final picked = await _askSeenName();
    if (picked == null) return;
    await _openName(picked.$1, seenName: picked.$2);
  }

  /// Username plus the name this person wants to see. The second value is null
  /// when they left it the same as the username.
  Future<(String, String?)?> _askSeenName({String username = ''}) async {
    final controller = TextEditingController(text: username);
    final seen = TextEditingController(text: username);
    var seenEdited = false;
    void follow() {
      if (!seenEdited) seen.text = controller.text.trim();
    }

    controller.addListener(follow);
    final picked = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        void submit() => Navigator.pop(context, (controller.text, seen.text));
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
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  prefixText: '@',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: seen,
                maxLength: 40,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                onChanged: (_) => seenEdited = true,
                onSubmitted: (_) => submit(),
                decoration: const InputDecoration(
                  labelText: 'Name you see',
                  helperText: 'Only you see this. The username stays the address.',
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: submit, child: const Text('Message')),
            ],
          ),
        );
      },
    );
    controller.removeListener(follow);
    controller.dispose();
    seen.dispose();
    if (!mounted || picked == null) return null;
    final handle = picked.$1
        .trim()
        .toLowerCase()
        .replaceFirst(RegExp(r'^@'), '');
    if (handle.isEmpty) return null;
    final shown = picked.$2.trim();
    final custom = shown.isNotEmpty && shown != handle ? shown : null;
    return (handle, custom);
  }

  Future<void> _startTyped(String raw) async {
    final query = raw.trim().toLowerCase().replaceFirst(RegExp(r'^@'), '');
    if (query.isEmpty || _busy) return;
    for (final item in _threads) {
      if (item.username.toLowerCase() == query) {
        await _openSaved(item);
        return;
      }
    }
    final picked = await _askSeenName(username: query);
    if (picked == null) return;
    await _openName(picked.$1, seenName: picked.$2);
  }

  Future<void> _renameThread(ChatThreadSummary item) async {
    final controller = TextEditingController(text: item.label);
    final next = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Edit name'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            onSubmitted: (value) => Navigator.pop(context, value),
            decoration: InputDecoration(
              labelText: 'Name you see',
              helperText: 'Leave blank to show @${item.username}',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (!mounted || next == null) return;
    final typed = next.trim();
    final name = typed == item.username ? '' : typed;
    try {
      final saved = await _api.setSeenName(item.username, name);
      if (!mounted) return;
      _applySeen(item.id, saved);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(chatErrorText(error))));
    }
  }

  void _applySeen(String id, String name) {
    if (!mounted) return;
    setState(() {
      if (_selectedId == id) _selectedSeen = name;
      _threads = [
        for (final thread in _threads)
          if (thread.id == id) thread.copyWith(name: name) else thread,
      ];
    });
    for (final thread in _threads) {
      if (thread.id != id) continue;
      final label = thread.label.trim();
      if (label.isEmpty) {
        ChatAlerts.labels.remove(id);
      } else {
        ChatAlerts.labels[id] = label;
      }
      break;
    }
    _keepThreads();
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
                    seenName: _selectedSeen,
                    group: _selectedGroup,
                    embedded: true,
                    onRead: _onRead,
                    onSeenName: (id, name) => _applySeen(id, name),
                    onLeft: _leftGroup,
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
              step ? 'Sign in or register' : 'Your username',
              style: pageTitleStyle(context),
            ),
            const SizedBox(height: 8),
            Text(
              step
                  ? 'People will not see this. Social Save does not send a code. The same phone or email, username, and password sign this device in.'
                  : 'A new username creates the account. Your existing username and password sign this device in. This phone and the PC can stay signed in together.',
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
            ] else ...[
              TextField(
                controller: _username,
                enabled: !_busy,
                autofocus: true,
                autocorrect: false,
                maxLength: 20,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  hintText: 'ada',
                  prefixText: '@',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _password,
                enabled: !_busy,
                obscureText: !_showPassword,
                autocorrect: false,
                enableSuggestions: false,
                maxLength: 64,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => unawaited(_register()),
                decoration: InputDecoration(
                  labelText: 'Password',
                  helperText: 'At least 6 characters.',
                  suffixIcon: IconButton(
                    tooltip: _showPassword ? 'Hide password' : 'Show password',
                    icon: Icon(
                      _showPassword
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                    ),
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                  ),
                ),
              ),
            ],
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
                  : Text(step ? 'Next' : 'Continue'),
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

  Future<void> _openAdmin() {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ChatAdminScreen()));
  }

  Future<void> _logOut() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Log out'),
          content: const Text(
            'This signs chat out on this device. Sign in again with the same phone or email, username, and password.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Log out'),
            ),
          ],
        );
      },
    );
    if (yes != true || !mounted) return;
    _poll?.cancel();
    _poll = null;
    try {
      await _api.logout();
    } catch (_) {
      // This device still signs out locally when the server is asleep.
    }
    await ChatSession.clear();
    ChatAlerts.reset();
    if (!mounted) return;
    setState(() {
      _signedIn = false;
      _user = null;
      _threads = const [];
      _selectedId = null;
      _selectedName = null;
      _selectedSeen = '';
      _selectedGroup = false;
      _step = 0;
      _error = null;
      _busy = false;
    });
  }

  Future<void> _archiveThread(ChatThreadSummary item) {
    final on = !ChatInboxFilter.archived.contains(item.id);
    return ChatInboxFilter.setArchived(item.id, on: on);
  }

  int _sectionUnread(bool groups) {
    var count = 0;
    for (final item in _threads) {
      final isGroup = item.group || item.id.startsWith('g');
      if (isGroup != groups) continue;
      if (ChatInboxFilter.hides(item.id, item.lastId)) continue;
      count += item.unread;
    }
    return count;
  }

  String _sectionLabel(String name, int unread) {
    if (unread <= 0) return name;
    return '$name · ${unread > 99 ? '99+' : unread}';
  }

  Future<void> _viewProfile(ChatThreadSummary item) async {
    final group = item.group || item.id.startsWith('g');
    if (group) {
      try {
        final info = await _api.group(item.id);
        if (!mounted) return;
        await showChatGroup(
          context,
          name: info.name.isEmpty ? item.label : info.name,
          code: info.code,
          members: info.members,
          onAdd: (value) async {
            final next = await _api.addMember(item.id, value);
            return next.members;
          },
          onRename: (value) async {
            final saved = await _api.renameGroup(item.id, value);
            if (mounted && saved.isNotEmpty) {
              setState(() {
                _threads = [
                  for (final row in _threads)
                    if (row.id == item.id) row.copyWith(name: saved) else row,
                ];
                if (_selectedId == item.id) _selectedSeen = saved;
              });
            }
            return saved;
          },
          onLeave: () async {
            await _api.leaveGroup(item.id);
            if (!mounted) return;
            setState(() {
              _threads = [
                for (final row in _threads)
                  if (row.id != item.id) row,
              ];
              if (_selectedId == item.id) {
                _selectedId = null;
                _selectedName = null;
                _selectedSeen = '';
                _selectedGroup = false;
              }
            });
          },
        );
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(chatErrorText(error))),
        );
      }
      return;
    }
    await showChatProfile(
      context,
      username: item.username,
      seenName: item.name,
      photoRev: item.photoRev,
      lastSeen: item.lastSeen,
      online: item.online,
      blocked: item.blocked,
      onBlock: (on) async {
        final blocked = await _api.block(item.username, on: on);
        if (mounted) unawaited(_loadThreads());
        return blocked;
      },
      onSeenName: (value) async {
        final saved = await _api.setSeenName(item.username, value);
        if (mounted) _applySeen(item.id, saved);
        return saved;
      },
    );
  }

  Future<void> _downloadProfile(ChatThreadSummary item) async {
    final messenger = ScaffoldMessenger.of(context);
    if (item.group || item.id.startsWith('g')) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Open the group profile and choose a person to download their photo.',
          ),
        ),
      );
      return;
    }
    final text = await downloadChatProfilePhoto(
      item.username,
      photoRev: item.photoRev,
    );
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _muteThread(ChatThreadSummary item) async {
    final on = !ChatInboxFilter.isMuted(item.id);
    await ChatInboxFilter.setMuted(item.id, on: on);
    if (!mounted) return;
    final name = item.label.trim().isEmpty
        ? (item.group ? 'this group' : 'this chat')
        : item.label.trim();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          on ? 'Notifications muted for $name' : 'Notifications on for $name',
        ),
      ),
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
        _selectedSeen = '';
        _selectedGroup = false;
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
        onTap: () => unawaited(_viewProfile(item)),
        child: ChatFace(
          name: item.group || item.username.isEmpty ? item.label : item.username,
          photoRev: item.group ? 0 : item.photoRev,
          online: item.online,
          size: ChatUiTokens.avatar,
        ),
      ),
      onOpen: () => unawaited(_openSaved(item)),
      onProfile: () => unawaited(_viewProfile(item)),
      onDownload: () => unawaited(_downloadProfile(item)),
      onArchive: () => unawaited(_archiveThread(item)),
      onMute: () => unawaited(_muteThread(item)),
      onDelete: () => unawaited(_hideThread(item)),
      onRename: item.group ? null : () => unawaited(_renameThread(item)),
    );
  }

  Widget _inboxList(
    bool wide,
    ChatUser user,
    String query,
    bool canStart,
    bool groups,
    List<ChatThreadSummary> shown,
    ColorScheme scheme,
  ) {
    final visible = [
      for (final item in shown)
        if (!ChatInboxFilter.hides(item.id, item.lastId)) item,
    ];
    final blocked = [
      for (final item in visible)
        if (query.isEmpty && item.blocked) item,
    ];
    final archived = [
      for (final item in visible)
        if (query.isEmpty &&
            !item.blocked &&
            ChatInboxFilter.archived.contains(item.id))
          item,
    ];
    final open = query.isEmpty
        ? [
            for (final item in visible)
              if (!item.blocked && !ChatInboxFilter.archived.contains(item.id))
                item,
          ]
        : visible;
    final showHeader = query.isEmpty && archived.isNotEmpty;
    final showBlocked = query.isEmpty && blocked.isNotEmpty;
    final archivedShown = showHeader && _showArchived ? archived.length : 0;
    final blockedShown = showBlocked && _showBlocked ? blocked.length : 0;
    final empty = !canStart && open.isEmpty && !showHeader && !showBlocked;
    final count =
        (canStart ? 1 : 0) +
        (showHeader ? 1 : 0) +
        archivedShown +
        (showBlocked ? 1 : 0) +
        blockedShown +
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
                onTap: () => unawaited(_startTyped(query)),
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
          if (showBlocked) {
            if (cursor == 0) {
              return ListTile(
                leading: const Icon(Icons.block_rounded),
                title: const Text('Blocked'),
                trailing: Icon(
                  _showBlocked
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                ),
                onTap: () => setState(() => _showBlocked = !_showBlocked),
              );
            }
            cursor--;
            if (_showBlocked && cursor < blocked.length) {
              return _threadTile(blocked[cursor], user.username, wide);
            }
            if (_showBlocked) cursor -= blocked.length;
          }
          if (cursor < open.length) {
            return _threadTile(open[cursor], user.username, wide);
          }
          if (query.isNotEmpty) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
              child: Text(
                groups
                    ? 'No groups match that search.'
                    : 'No chats match that search.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
              ),
            );
          }
          if (groups) {
            return ChatEmptyGroups(onCreate: () => unawaited(_newGroup()));
          }
          return ChatEmptyInbox(onStart: () => _findFocus.requestFocus());
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
    final section = [
      for (final item in _threads)
        if ((item.group || item.id.startsWith('g')) == _groups) item,
    ];
    final shown = [
      for (final item in section)
        if (query.isEmpty ||
            item.username.contains(query) ||
            item.label.toLowerCase().contains(query) ||
            item.lastText.toLowerCase().contains(query) ||
            ChatDrafts.peek(item.id).toLowerCase().contains(query))
          item,
    ];
    final canStart =
        !_groups &&
        query.isNotEmpty &&
        RegExp(r'^[a-z0-9_]{1,20}$').hasMatch(query) &&
        shown.every((item) => item.username != query);
    return Scaffold(
      appBar: AppBar(
        title: Text(_groups ? 'Groups' : 'Chats'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Account',
            onSelected: (value) {
              if (value == 'people') unawaited(_openAdmin());
              if (value == 'group') unawaited(_newGroup());
              if (value == 'join') unawaited(_joinGroup());
              if (value == 'logout') unawaited(_logOut());
            },
            itemBuilder: (context) => [
              if (user.isAdmin)
                const PopupMenuItem(
                  value: 'people',
                  child: Text('Registered people'),
                ),
              const PopupMenuItem(value: 'group', child: Text('New group')),
              const PopupMenuItem(value: 'join', child: Text('Join a group')),
              const PopupMenuItem(value: 'logout', child: Text('Log out')),
            ],
          ),
          IconButton(
            tooltip: 'Your profile',
            onPressed: () => unawaited(
              showChatProfile(
                context,
                username: user.username,
                contact: user.contact,
                photoRev: user.photoRev,
                onLogOut: () => unawaited(_logOut()),
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
        tooltip: _groups ? 'New group' : 'New chat',
        onPressed: _busy
            ? null
            : () => unawaited(_groups ? _newGroup() : _newChat()),
        child: Icon(_groups ? Icons.group_add_rounded : Icons.chat_rounded),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: ChatSearchField(
              controller: _find,
              focusNode: _findFocus,
              hintText: _groups ? 'Search groups' : 'Search or start a chat',
              onChanged: (_) => setState(() {}),
              onSubmitted: (value) {
                if (_groups) return;
                unawaited(_startTyped(value));
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: LiquidOrSegmented<bool>(
              segments: [
                ButtonSegment(
                  value: false,
                  label: Text(
                    _sectionLabel('Chats', _sectionUnread(false)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  icon: const Icon(Icons.chat_bubble_outline_rounded),
                ),
                ButtonSegment(
                  value: true,
                  label: Text(
                    _sectionLabel('Groups', _sectionUnread(true)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  icon: const Icon(Icons.groups_rounded),
                ),
              ],
              selected: _groups,
              onSelectionChanged: (value) {
                final next = value.first;
                if (next == _groups) return;
                setState(() {
                  _groups = next;
                  _showArchived = false;
                  _showBlocked = false;
                });
              },
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
          Expanded(
            child: _inboxList(
              wide,
              user,
              query,
              canStart,
              _groups,
              shown,
              scheme,
            ),
          ),
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
