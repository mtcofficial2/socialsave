import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/shared/widgets/page_layout.dart';

enum _ContactKind { phone, email }

/// Register with a phone number or an email, then message people by username.
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
  String? _error;
  bool _booting = true;
  bool _signedIn = false;
  bool _busy = false;
  bool _refreshing = false;

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

  Future<void> _startChat() async {
    final name = _find.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final opened = await _api.openThread(name);
      if (!mounted) return;
      _find.clear();
      setState(() => _busy = false);
      await context.push('/chat/${opened.id}', extra: opened.username);
      if (mounted) unawaited(_loadThreads());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = chatErrorText(error);
      });
    }
  }

  Future<void> _openThread(ChatThreadSummary item) async {
    await context.push('/chat/${item.id}', extra: item.username);
    if (mounted) unawaited(_loadThreads());
  }

  Future<void> _copyUsername() async {
    final name = _user?.username ?? '';
    if (name.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: '@$name'));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Username copied')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('Chat', style: pageTitleStyle(context)),
      ),
      body: _booting
          ? _Waiting(text: 'Opening chat. The first open can take a moment.')
          : !_signedIn
              ? _registerForm(scheme)
              : _user == null
                  ? _retry(scheme)
                  : _inbox(scheme),
    );
  }

  Widget _registerForm(ColorScheme scheme) {
    final phone = _kind == _ContactKind.phone;
    return ListView(
      padding: pagePadding(context, top: 8, bottom: 24),
      children: [
        Text(
          'Register with a phone number or an email, then choose a username. People message that username.',
          style: TextStyle(fontSize: 15, height: 1.4, color: scheme.onSurface),
        ),
        const SizedBox(height: 8),
        Text(
          'Social Save does not send a text or an email code. This device keeps the account, and the username cannot be changed later.',
          style: TextStyle(fontSize: 13, height: 1.4, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
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
          keyboardType: phone ? TextInputType.phone : TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: phone ? 'Phone number' : 'Email',
            hintText: phone ? '256700000111' : 'you@example.com',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _username,
          enabled: !_busy,
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.done,
          autocorrect: false,
          maxLength: 20,
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
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : () => unawaited(_register()),
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Create username'),
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
    );
  }

  Widget _retry(ColorScheme scheme) {
    return ListView(
      padding: pagePadding(context, top: 24, bottom: 24),
      children: [
        Text(_error ?? 'Chat is not reachable right now.', style: TextStyle(color: scheme.error, height: 1.4)),
        const SizedBox(height: 16),
        FilledButton(onPressed: () => unawaited(_boot()), child: const Text('Try again')),
      ],
    );
  }

  Widget _inbox(ColorScheme scheme) {
    final user = _user!;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: pagePadding(context, top: 8, bottom: 12),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Your username is @${user.username}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy username',
                    onPressed: () => unawaited(_copyUsername()),
                    icon: const Icon(Icons.copy_rounded),
                  ),
                ],
              ),
              if (user.contact.isNotEmpty)
                Text(
                  'Registered with ${user.contact}',
                  style: TextStyle(fontSize: 13, height: 1.35, color: scheme.onSurfaceVariant),
                ),
              const SizedBox(height: 12),
              Text(
                'Message someone by their username. In a chat, tap a link to save it.',
                style: TextStyle(fontSize: 13, height: 1.4, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _find,
                      enabled: !_busy,
                      autocorrect: false,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => unawaited(_startChat()),
                      decoration: const InputDecoration(
                        hintText: 'Message a username',
                        prefixText: '@',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _busy ? null : () => unawaited(_startChat()),
                    child: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Chat'),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: scheme.error, height: 1.35)),
              ],
              const SizedBox(height: 16),
              if (_threads.isEmpty)
                Text(
                  'No chats yet. Enter a username to start one.',
                  style: TextStyle(fontSize: 14, height: 1.4, color: scheme.onSurfaceVariant),
                )
              else
                for (final item in _threads)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('@${item.username}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(
                      item.lastText.isEmpty ? 'No messages yet' : item.lastText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: item.lastAt == null
                        ? null
                        : Text(
                            TimeOfDay.fromDateTime(item.lastAt!.toLocal()).format(context),
                            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                          ),
                    onTap: () => unawaited(_openThread(item)),
                  ),
            ],
          ),
        ),
      ],
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
