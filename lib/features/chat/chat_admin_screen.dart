import 'package:flutter/material.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/features/chat/chat_thread_screen.dart';
import 'package:social_save/shared/widgets/page_layout.dart';

/// Everyone who registered for chat. The server returns this only for the
/// admin account.
class ChatAdminScreen extends StatefulWidget {
  const ChatAdminScreen({super.key});

  @override
  State<ChatAdminScreen> createState() => _ChatAdminScreenState();
}

class _ChatAdminScreenState extends State<ChatAdminScreen> {
  final ChatApi _api = ChatApi();
  final TextEditingController _query = TextEditingController();
  List<ChatDirectoryEntry> _people = const [];
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final first = _people.isEmpty;
    if (mounted && (_error != null || !first)) {
      setState(() {
        _error = null;
        _loading = first;
      });
    }
    try {
      final people = await _api.directory();
      if (!mounted) return;
      setState(() {
        _people = people;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = chatErrorText(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = _people.length;
    final phones = _people.where((person) => person.phone.isNotEmpty).length;
    final emails = _people.where((person) => person.email.isNotEmpty).length;
    final passwords = _people.where((person) => person.hasPassword).length;
    final query = _query.text.trim().toLowerCase();
    final shown = [
      for (final person in _people)
        if (query.isEmpty ||
            person.username.contains(query) ||
            person.phone.contains(query) ||
            person.email.toLowerCase().contains(query))
          person,
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(count == 0 ? 'Registered people' : '$count registered'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: pagePadding(context, top: 8, bottom: 24),
          children: [
            Text(
              'Everyone who signed up for chat on Social Save.',
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
            ),
            if (!_loading && _error == null && count > 0) ...[
              const SizedBox(height: 8),
              Text(
                '$count people · $phones with a phone · $emails with an email · $passwords with a password',
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
              ),
            ],
            if (!_loading && _error == null && _api.lastStorage.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                _storageText(_api.lastStorage),
                style: TextStyle(
                  color: _api.lastStorage == 's3' ? scheme.primary : scheme.error,
                  height: 1.4,
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: TextStyle(color: scheme.error, height: 1.4)),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('Try again')),
            ],
            if (!_loading && _error == null && count > 0) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _query,
                autocorrect: false,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Search',
                  hintText: 'Username, phone, or email',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
            ],
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_people.isEmpty && _error == null)
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Text(
                  _api.lastStorage == 's3'
                      ? 'No one has registered yet.'
                      : 'The server has no accounts. It may have restarted and lost them. Ask people to register again.',
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
                ),
              )
            else if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Text(
                  'No one matches that search.',
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
                ),
              )
            else
              for (final person in shown)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: ChatFace(name: person.username, size: 44),
                  title: Text('@${person.username}'),
                  subtitle: Text(
                    [
                      if (person.contact.isNotEmpty) person.contact,
                      if (person.created != null) 'Joined ${_when(person.created!)}',
                      _seen(context, person.lastSeen),
                      person.hasPassword ? 'Password set' : 'No password yet',
                    ].join('\n'),
                    style: const TextStyle(height: 1.35),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

String _seen(BuildContext context, DateTime? at) {
  if (at == null) return 'Not seen yet';
  final clock = TimeOfDay.fromDateTime(at.toLocal()).format(context);
  final label = chatPresenceLabel(at, false, DateTime.now(), clock);
  if (label.isEmpty) return 'Not seen yet';
  return label[0].toUpperCase() + label.substring(1);
}

String _storageText(String storage) {
  switch (storage) {
    case 's3':
      return 'Storage: saved online. Accounts stay after the server restarts.';
    case 's3-error':
      return 'Storage: the server could not read saved accounts. It will not overwrite them, but this list may be incomplete.';
    default:
      return 'Storage: temporary. Accounts are lost each time the server restarts. Add S3 settings on Render to keep them.';
  }
}

String _when(DateTime at) {
  final local = at.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}
