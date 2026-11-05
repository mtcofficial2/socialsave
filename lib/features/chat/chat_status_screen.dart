import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_ui.dart';

const _seenKey = 'chat.status.seen.v1';

const statusTones = <Color>[
  Color(0xFF075E54),
  Color(0xFF128C7E),
  Color(0xFF0E6655),
  Color(0xFF1A5276),
  Color(0xFF6C3483),
  Color(0xFF922B21),
  Color(0xFF1B4F72),
  Color(0xFF196F3D),
];

Color statusTone(String id) {
  var hash = 0;
  for (final unit in id.codeUnits) {
    hash = (hash + unit) & 0x7fffffff;
  }
  return statusTones[hash % statusTones.length];
}

/// A short age, in the same words a status list uses.
String statusAge(DateTime at, DateTime now) {
  final delta = now.difference(at);
  if (delta.isNegative || delta.inSeconds < 45) return 'Just now';
  if (delta.inMinutes < 60) {
    final n = delta.inMinutes;
    return n <= 1 ? '1 minute ago' : '$n minutes ago';
  }
  final start = DateTime(now.year, now.month, now.day);
  final day = DateTime(at.year, at.month, at.day);
  if (day == start) {
    final n = delta.inHours;
    return n <= 1 ? '1 hour ago' : '$n hours ago';
  }
  if (day == start.subtract(const Duration(days: 1))) return 'Yesterday';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[at.month - 1]} ${at.day}';
}

/// Words for how many people have opened a text status.
String statusViewLabel(int count) {
  if (count <= 0) return 'No views yet';
  if (count == 1) return '1 view';
  return '$count views';
}

/// Views on [me]'s newest text status. Null when there is no status.
int? ownStatusViews(List<ChatStatusNote> notes, String me) {
  final mine = me.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
  if (mine.isEmpty) return null;
  ChatStatusNote? latest;
  for (final note in notes) {
    final name = note.name.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
    if (name != mine) continue;
    if (latest == null || note.at.isAfter(latest.at)) latest = note;
  }
  return latest?.views.length;
}

class ChatStatusScreen extends StatefulWidget {
  const ChatStatusScreen({super.key});

  @override
  State<ChatStatusScreen> createState() => _ChatStatusScreenState();
}

class _ChatStatusScreenState extends State<ChatStatusScreen> {
  final ChatApi _api = ChatApi();
  List<ChatStatusNote> _rows = const [];
  Set<String> _seen = {};
  String _me = '';
  bool _loading = true;
  String? _problem;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final me = await ChatSession.username();
      final rows = await _api.statuses();
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _me = me;
        _rows = rows;
        _seen = (prefs.getStringList(_seenKey) ?? const []).toSet();
        _loading = false;
        _problem = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _problem = chatErrorText(error);
      });
    }
  }

  Future<void> _mark(Iterable<String> ids) async {
    final next = {..._seen, ...ids.where((id) => id.isNotEmpty)};
    if (next.length == _seen.length) return;
    setState(() => _seen = next);
    final prefs = await SharedPreferences.getInstance();
    final kept = next.toList();
    if (kept.length > 400) {
      kept.removeRange(0, kept.length - 400);
    }
    await prefs.setStringList(_seenKey, kept);
  }

  bool _mine(ChatStatusNote note) {
    final me = _me.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
    final name = note.name.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
    return me.isNotEmpty && me == name;
  }

  List<ChatStatusNote> _sorted(List<ChatStatusNote> notes) {
    final copy = List<ChatStatusNote>.of(notes);
    copy.sort((a, b) => b.at.compareTo(a.at));
    return copy;
  }

  Future<void> _open(List<ChatStatusNote> notes, String title) async {
    final ordered = _sorted(notes);
    if (ordered.isEmpty || !mounted) return;
    final own = ordered.every(_mine);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => _StatusViewer(notes: ordered, title: title, own: own),
      ),
    );
    await _mark(ordered.map((note) => note.id));
    if (own) await _load();
  }

  Future<void> _compose() async {
    final posted = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (context) => const _StatusComposer()),
    );
    if (posted == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final dark = ChatUiTokens.dark(context);
    final mine = _sorted(_rows.where(_mine).toList());
    final others = <String, List<ChatStatusNote>>{};
    for (final note in _rows) {
      if (_mine(note)) continue;
      final key = note.name.trim().isEmpty ? 'Someone' : note.name.trim();
      others.putIfAbsent(key, () => []).add(note);
    }
    final names = others.keys.toList()
      ..sort((a, b) => others[b]!.map((n) => n.at).reduce((x, y) => x.isAfter(y) ? x : y)
          .compareTo(others[a]!.map((n) => n.at).reduce((x, y) => x.isAfter(y) ? x : y)));
    final latest = mine.isEmpty ? null : mine.first;
    return Scaffold(
      backgroundColor: ChatUiTokens.canvas(dark),
      appBar: AppBar(
        backgroundColor: ChatUiTokens.canvas(dark),
        title: const Text('Status'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  if (_problem != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                      child: Text(_problem!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  ListTile(
                    isThreeLine: latest != null,
                    contentPadding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                    leading: _StatusFace(
                      letter: _me.isEmpty ? '+' : _me.substring(0, 1).toUpperCase(),
                      fresh: latest != null,
                      badge: true,
                      onBadge: _compose,
                    ),
                    title: const Text('My status', style: TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: latest == null
                        ? const Text('Tap to add a status update')
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${statusAge(latest.at, DateTime.now())} · ${latest.text}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                statusViewLabel(latest.views.length),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                    onTap: latest == null ? _compose : () => unawaited(_open(mine, 'My status')),
                  ),
                  if (names.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 18, 16, 6),
                      child: Text(
                        'Recent updates',
                        style: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF667781)),
                      ),
                    ),
                  if (names.isEmpty && _problem == null)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 28, 16, 16),
                      child: Text(
                        'No updates right now. A text update stays up for 24 hours.',
                        style: TextStyle(color: Color(0xFF667781)),
                      ),
                    ),
                  for (final name in names)
                    ListTile(
                      leading: _StatusFace(
                        letter: name.substring(0, 1).toUpperCase(),
                        fresh: others[name]!.any((note) => !_seen.contains(note.id)),
                      ),
                      title: Text(name.startsWith('@') ? name : '@$name', style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        statusAge(
                          others[name]!.map((note) => note.at).reduce((a, b) => a.isAfter(b) ? a : b),
                          DateTime.now(),
                        ),
                      ),
                      onTap: () => unawaited(_open(others[name]!, name)),
                    ),
                ],
              ),
            ),
    );
  }
}

class _StatusFace extends StatelessWidget {
  const _StatusFace({
    required this.letter,
    required this.fresh,
    this.badge = false,
    this.onBadge,
  });

  final String letter;
  final bool fresh;
  final bool badge;
  final VoidCallback? onBadge;

  @override
  Widget build(BuildContext context) {
    final face = Container(
      width: 56,
      height: 56,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: fresh ? ChatUiTokens.brand : const Color(0xFF8696A0),
          width: 2,
        ),
      ),
      child: CircleAvatar(
        backgroundColor: const Color(0xFF1F2C34),
        child: Text(
          letter.isEmpty ? '?' : letter.substring(0, 1).toUpperCase(),
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
      ),
    );
    if (!badge) return face;
    return SizedBox(
      width: 56,
      height: 56,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          face,
          Positioned(
            right: -2,
            bottom: -2,
            child: Material(
              color: ChatUiTokens.brand,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onBadge,
                child: const SizedBox(
                  width: 22,
                  height: 22,
                  child: Icon(Icons.add, size: 16, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusViewer extends StatefulWidget {
  const _StatusViewer({required this.notes, required this.title, required this.own});

  final List<ChatStatusNote> notes;
  final String title;
  final bool own;

  @override
  State<_StatusViewer> createState() => _StatusViewerState();
}

class _StatusViewerState extends State<_StatusViewer> with SingleTickerProviderStateMixin {
  late final AnimationController _bar;
  final Set<String> _reported = {};
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _bar = AnimationController(vsync: this, duration: const Duration(seconds: 6));
    _arm();
    _report(widget.notes.first);
  }

  void _report(ChatStatusNote note) {
    if (widget.own || note.id.isEmpty || !_reported.add(note.id)) return;
    unawaited(_sendView(note.id));
  }

  Future<void> _sendView(String id) async {
    try {
      await ChatApi().markStatusView(id);
    } catch (_) {}
  }

  void _arm() {
    _bar.forward(from: 0).whenComplete(() {
      if (mounted) _step(1);
    });
  }

  void _step(int by) {
    final next = _index + by;
    if (next < 0) {
      _arm();
      return;
    }
    if (next >= widget.notes.length) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _index = next);
    _report(widget.notes[next]);
    _arm();
  }

  Future<void> _viewers(ChatStatusNote note) async {
    if (!widget.own) return;
    _bar.stop();
    final names = note.views;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: names.isEmpty
              ? const Padding(
                  padding: EdgeInsets.fromLTRB(24, 8, 24, 28),
                  child: Text('No views yet'),
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text('Viewed by', style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                    for (final name in names)
                      ListTile(
                        leading: const Icon(Icons.person_outline),
                        title: Text(name.startsWith('@') ? name : '@$name'),
                      ),
                  ],
                ),
        );
      },
    );
    if (mounted && !_bar.isCompleted) unawaited(_bar.forward());
  }

  @override
  void dispose() {
    _bar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.notes[_index];
    final color = statusTone(note.id);
    return Scaffold(
      backgroundColor: color,
      body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            child: Column(
              children: [
                AnimatedBuilder(
                  animation: _bar,
                  builder: (context, _) {
                    return Row(
                      children: [
                        for (var i = 0; i < widget.notes.length; i++)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 2),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: i < _index ? 1 : (i == _index ? _bar.value : 0),
                                  minHeight: 2.5,
                                  backgroundColor: Colors.white24,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: Colors.white24,
                      child: Text(
                        widget.title.substring(0, 1).toUpperCase(),
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                          ),
                          Text(
                            widget.own
                                ? '${statusAge(note.at, DateTime.now())} · ${statusViewLabel(note.views.length)}'
                                : statusAge(note.at, DateTime.now()),
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                  ],
                ),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) {
                      final width = MediaQuery.sizeOf(context).width;
                      _step(details.localPosition.dx < width / 3 ? -1 : 1);
                    },
                    child: Center(
                      child: Text(
                        note.text,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                      ),
                    ),
                  ),
                ),
                if (widget.own)
                  TextButton.icon(
                    onPressed: () => unawaited(_viewers(note)),
                    icon: const Icon(Icons.remove_red_eye_outlined, color: Colors.white),
                    label: Text(
                      statusViewLabel(note.views.length),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
          ),
        ),
    );
  }
}

class _StatusComposer extends StatefulWidget {
  const _StatusComposer();

  @override
  State<_StatusComposer> createState() => _StatusComposerState();
}

class _StatusComposerState extends State<_StatusComposer> {
  final TextEditingController _text = TextEditingController();
  final ChatApi _api = ChatApi();
  int _tone = 0;
  String _audience = 'all';
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String get _audienceLabel {
    switch (_audience) {
      case 'contacts':
        return 'Contacts';
      case 'only':
        return 'Selected people';
      case 'except':
        return 'Contacts, except some';
      default:
        return 'Everyone';
    }
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty || _busy) return;
    List<String> allow = const [];
    List<String> deny = const [];
    if (_audience == 'only' || _audience == 'except') {
      final names = await _askNames(
        _audience == 'only' ? 'Who can see it' : 'Hide from',
      );
      if (names == null || !mounted) return;
      if (_audience == 'only') {
        allow = names;
      } else {
        deny = names;
      }
    }
    setState(() => _busy = true);
    try {
      await _api.postStatus(text: text, audience: _audience, allow: allow, deny: deny);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(chatErrorText(error))));
    }
  }

  Future<List<String>?> _askNames(String title) {
    final field = TextEditingController();
    return showDialog<List<String>>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: TextField(
            controller: field,
            decoration: const InputDecoration(hintText: '@names, separated by spaces'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final names = [
                  for (final part in field.text.split(RegExp(r'[\s,]+')))
                    if (part.trim().isNotEmpty) part.trim().replaceFirst(RegExp(r'^@'), ''),
                ];
                Navigator.pop(context, names);
              },
              child: const Text('Done'),
            ),
          ],
        );
      },
    ).whenComplete(field.dispose);
  }

  Future<void> _pickAudience() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(title: const Text('Everyone'), onTap: () => Navigator.pop(context, 'all')),
              ListTile(title: const Text('Contacts'), onTap: () => Navigator.pop(context, 'contacts')),
              ListTile(title: const Text('Selected people'), onTap: () => Navigator.pop(context, 'only')),
              ListTile(
                title: const Text('Contacts, except some'),
                onTap: () => Navigator.pop(context, 'except'),
              ),
            ],
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    setState(() => _audience = picked);
  }

  @override
  Widget build(BuildContext context) {
    final color = statusTones[_tone % statusTones.length];
    return Scaffold(
      backgroundColor: color,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: const Text('New update'),
        actions: [
          IconButton(
            tooltip: 'Color',
            onPressed: () => setState(() => _tone = (_tone + 1) % statusTones.length),
            icon: const Icon(Icons.palette_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: TextField(
                    controller: _text,
                    autofocus: true,
                    maxLength: 400,
                    maxLines: null,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700),
                    cursorColor: Colors.white,
                    decoration: const InputDecoration(
                      counterText: '',
                      border: InputBorder.none,
                      hintText: 'Type a status',
                      hintStyle: TextStyle(color: Colors.white54, fontSize: 28, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: _busy ? null : _pickAudience,
                    icon: const Icon(Icons.visibility_outlined, color: Colors.white),
                    label: Text(_audienceLabel, style: const TextStyle(color: Colors.white)),
                  ),
                  const Spacer(),
                  FloatingActionButton(
                    backgroundColor: Colors.white,
                    foregroundColor: color,
                    onPressed: _busy ? null : _send,
                    child: _busy
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
