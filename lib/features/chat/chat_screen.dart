import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/features/chat/chat_profile.dart';
import 'package:social_save/features/chat/chat_thread_screen.dart';
import 'package:social_save/shared/widgets/app_logo.dart';
import 'package:social_save/shared/widgets/page_layout.dart';

enum _ContactKind { phone, email }

/// Chats, in the shape of a messenger: a list, then a conversation.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final ChatApi _api = ChatApi();
  final TextEditingController _contact = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _find = TextEditingController();
  Timer? _poll;
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

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _contact.dispose();
    _username.dispose();
    _find.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final token = await ChatSession.token();
    if (!mounted) return;
    if (token == null) {
      setState(() {
        _signedIn = false;
        _user = null;
        _booting = false;
      });
      return;
    }
    setState(() {
      _signedIn = true;
      _booting = true;
      _error = null;
    });
    try {
      final user = await _api.me();
      if (!mounted) return;
      await ChatSession.save(token: token, username: user.username, contact: user.contact);
      if (!mounted) return;
      setState(() {
        _user = user;
        _booting = false;
      });
      _startPoll();
      await _loadThreads();
    } catch (error) {
      if (!mounted) return;
      if (chatNeedsRegister(error)) {
        await ChatSession.clear();
        if (!mounted) return;
        setState(() {
          _signedIn = false;
          _user = null;
          _booting = false;
          _error = null;
        });
        return;
      }
      setState(() {
        _booting = false;
        _error = chatErrorText(error);
      });
    }
  }

  void _startPoll() {
    _poll ??= Timer.periodic(const Duration(seconds: 5), (_) => unawaited(_loadThreads()));
  }

  Future<void> _loadThreads() async {
    if (_refreshing || _user == null) return;
    _refreshing = true;
    try {
      final items = await _api.threads();
      if (!mounted) return;
      setState(() {
        _threads = items;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      if (chatNeedsRegister(error)) {
        await ChatSession.clear();
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
      setState(() => _error = chatErrorText(error));
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
      final ok = RegExp(r'^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$').hasMatch(email);
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
      final ok = RegExp(r'^[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}$').hasMatch(email);
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
          padding: EdgeInsets.fromLTRB(20, 4, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('New chat', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
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

  void _onRead(String id, int lastId) {
    setState(() {
      _threads = [
        for (final item in _threads)
          if (item.id == id)
            ChatThreadSummary(
              id: item.id,
              username: item.username,
              lastText: item.lastText,
              lastAt: item.lastAt,
              lastId: item.lastId < lastId ? lastId : item.lastId,
              lastFrom: item.lastFrom,
              lastStatus: item.lastStatus,
              unread: 0,
            )
          else
            item,
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_booting) {
      return const Scaffold(body: _Waiting(text: 'Opening chats. The first open can take a moment.'));
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
              style: TextStyle(fontSize: 14, height: 1.4, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            if (step) ...[
              SegmentedButton<_ContactKind>(
                segments: const [
                  ButtonSegment(value: _ContactKind.phone, label: Text('Phone')),
                  ButtonSegment(value: _ContactKind.email, label: Text('Email')),
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
                keyboardType: phone ? TextInputType.phone : TextInputType.emailAddress,
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
              Text(_error!, style: TextStyle(color: scheme.error, height: 1.35)),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : () => step ? _nextStep() : unawaited(_register()),
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
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
                  style: TextStyle(fontSize: 13, height: 1.35, color: scheme.onSurfaceVariant),
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
          Text(_error ?? 'Chat is not reachable right now.', style: TextStyle(color: scheme.error, height: 1.4)),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => unawaited(_boot()), child: const Text('Try again')),
        ],
      ),
    );
  }

  Widget _inbox(bool wide) {
    final scheme = Theme.of(context).colorScheme;
    final user = _user!;
    final query = _find.text.trim().toLowerCase().replaceFirst(RegExp(r'^@'), '');
    final shown = [
      for (final item in _threads)
        if (query.isEmpty || item.username.contains(query) || item.lastText.toLowerCase().contains(query)) item,
    ];
    final canStart = query.isNotEmpty && RegExp(r'^[a-z0-9_]{1,20}$').hasMatch(query) && shown.every((item) => item.username != query);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            tooltip: 'Your profile',
            onPressed: () => unawaited(showChatProfile(context, username: user.username, contact: user.contact)),
            icon: ChatAvatar(name: user.username, size: 32),
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
            child: TextField(
              controller: _find,
              autocorrect: false,
              onChanged: (_) => setState(() {}),
              onSubmitted: (value) => unawaited(_openName(value)),
              decoration: InputDecoration(
                hintText: 'Search or start a chat',
                prefixIcon: const Icon(Icons.search_rounded),
                filled: true,
                isDense: true,
                fillColor: scheme.surfaceContainerHighest,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(_error!, style: TextStyle(color: scheme.error, height: 1.35)),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadThreads,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  if (canStart)
                    ListTile(
                      leading: const Icon(Icons.person_add_alt_1_rounded),
                      title: Text('Message @$query'),
                      onTap: () => unawaited(_openName(query)),
                    ),
                  if (shown.isEmpty && !canStart)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
                      child: Text(
                        _threads.isEmpty ? 'No chats yet. Start one with a username.' : 'No chats match that search.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
                      ),
                    ),
                  for (final item in shown) _ChatRow(
                    item: item,
                    me: user.username,
                    selected: wide && item.id == _selectedId,
                    onOpen: () => unawaited(_openSaved(item)),
                    onProfile: () => unawaited(showChatProfile(context, username: item.username)),
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

class _ChatRow extends StatelessWidget {
  const _ChatRow({
    required this.item,
    required this.me,
    required this.selected,
    required this.onOpen,
    required this.onProfile,
  });

  final ChatThreadSummary item;
  final String me;
  final bool selected;
  final VoidCallback onOpen;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unread = item.unread > 0;
    final stamp = item.lastAt == null ? '' : chatListStamp(item.lastAt!, DateTime.now(), TimeOfDay.fromDateTime(item.lastAt!.toLocal()).format(context));
    final preview = chatPreview(item.lastText, item.lastFrom, me);
    return Material(
      color: selected ? scheme.primary.withValues(alpha: 0.10) : Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              GestureDetector(
                onTap: onProfile,
                child: ChatAvatar(name: item.username),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.username,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, fontWeight: unread ? FontWeight.w800 : FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (item.lastFrom == me && item.lastStatus.isNotEmpty) ...[
                          _Tick(status: item.lastStatus, muted: scheme.onSurfaceVariant),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: unread ? scheme.onSurface : scheme.onSurfaceVariant,
                              fontWeight: unread ? FontWeight.w700 : FontWeight.w400,
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
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (stamp.isNotEmpty)
                    Text(
                      stamp,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                        color: unread ? const Color(0xFF25D366) : scheme.onSurfaceVariant,
                      ),
                    ),
                  if (unread) ...[
                    const SizedBox(height: 6),
                    _Badge(count: item.unread),
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

class _Tick extends StatelessWidget {
  const _Tick({required this.status, required this.muted});

  final String status;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    return Icon(
      status == 'sent' ? Icons.done_rounded : Icons.done_all_rounded,
      size: 16,
      color: status == 'read' ? const Color(0xFF53BDEB) : muted,
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: const BoxDecoration(color: Color(0xFF25D366), borderRadius: BorderRadius.all(Radius.circular(12))),
      child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
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
          Text('Select a chat to start messaging', style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
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
            Text(text, textAlign: TextAlign.center, style: TextStyle(height: 1.4, color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
