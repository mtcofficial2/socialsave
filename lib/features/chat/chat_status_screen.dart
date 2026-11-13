import 'dart:async';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_profile.dart';
import 'package:social_save/features/chat/chat_ui.dart';
import 'package:social_save/features/chat/day_streak.dart';
import 'package:social_save/features/chat/emoji_panel.dart';
import 'package:social_save/features/chat/link_text.dart';
import 'package:social_save/features/chat/status_fonts.dart';
import 'package:social_save/features/chat/status_link_card.dart';

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

/// Words under a status. A photo with no caption says Photo.
String statusPreview(ChatStatusNote note) {
  final text = note.text.trim();
  if (text.isNotEmpty) return text;
  if (note.image.isNotEmpty) return 'Photo';
  return 'Update';
}

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

/// How many text updates [me] has up right now.
int ownStatusCount(List<ChatStatusNote> notes, String me) {
  final mine = me.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
  if (mine.isEmpty) return 0;
  var count = 0;
  for (final note in notes) {
    final name = note.name.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
    if (name == mine) count++;
  }
  return count;
}

/// One arc per update. A gap between arcs shows that there is more than one.
int statusRingSegments(int count) {
  if (count < 1) return 1;
  if (count > 12) return 12;
  return count;
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
  int _streak = 0;

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
      final streak = await DayStreakStore.touch();
      if (!mounted) return;
      setState(() {
        _me = me;
        _rows = rows;
        _seen = (prefs.getStringList(_seenKey) ?? const []).toSet();
        _streak = streak;
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
                    leading: StatusFace(
                      letter: _me.isEmpty ? '+' : _me.substring(0, 1).toUpperCase(),
                      segments: statusRingSegments(mine.length),
                      seen: [for (final _ in mine) false],
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
                                '${statusAge(latest.at, DateTime.now())} · ${statusPreview(latest)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                [
                                  statusViewLabel(latest.views.length),
                                  if (_streak > 0) streakLabel(_streak),
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                    onTap: latest == null ? _compose : () => unawaited(_open(mine, 'My status')),
                  ),
                  if (_streak > 0)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(88, 0, 16, 4),
                      child: Text(
                        'Come back tomorrow to keep your streak.',
                        style: TextStyle(color: Color(0xFF667781), fontSize: 12.5),
                      ),
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
                      leading: StatusFace(
                        letter: name.substring(0, 1).toUpperCase(),
                        segments: statusRingSegments(others[name]!.length),
                        seen: [
                          for (final note in _sorted(others[name]!))
                            _seen.contains(note.id),
                        ],
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

class StatusFace extends StatelessWidget {
  const StatusFace({
    super.key,
    required this.letter,
    this.segments = 1,
    this.seen = const [],
    this.badge = false,
    this.onBadge,
  });

  final String letter;
  final int segments;
  final List<bool> seen;
  final bool badge;
  final VoidCallback? onBadge;

  @override
  Widget build(BuildContext context) {
    final count = statusRingSegments(segments);
    final face = SizedBox(
      width: 56,
      height: 56,
      child: CustomPaint(
        painter: _StatusRingPainter(segments: count, seen: seen),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: CircleAvatar(
            backgroundColor: const Color(0xFF1F2C34),
            child: Text(
              letter.isEmpty ? '?' : letter.substring(0, 1).toUpperCase(),
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
            ),
          ),
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

class _StatusRingPainter extends CustomPainter {
  const _StatusRingPainter({required this.segments, required this.seen});

  final int segments;
  final List<bool> seen;

  @override
  void paint(Canvas canvas, Size size) {
    final count = statusRingSegments(segments);
    const stroke = 2.6;
    final rect = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    if (count <= 1) {
      final opened = seen.isNotEmpty && seen.first;
      paint.color = opened ? const Color(0xFF8696A0) : ChatUiTokens.brand;
      if (seen.isEmpty) paint.color = const Color(0xFF8696A0);
      canvas.drawArc(rect, 0, math.pi * 2, false, paint);
      return;
    }
    const gap = 0.28;
    final sweep = (math.pi * 2 / count) - gap;
    final start = -math.pi / 2 + gap / 2;
    for (var i = 0; i < count; i++) {
      final opened = i < seen.length && seen[i];
      paint.color = opened ? const Color(0xFF8696A0) : ChatUiTokens.brand;
      canvas.drawArc(rect, start + i * (sweep + gap), sweep, false, paint);
    }
  }

  @override
  bool shouldRepaint(_StatusRingPainter old) {
    if (old.segments != segments || old.seen.length != seen.length) return true;
    for (var i = 0; i < seen.length; i++) {
      if (old.seen[i] != seen[i]) return true;
    }
    return false;
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
  late List<ChatStatusNote> _notes;
  final Set<String> _reported = {};
  int _index = 0;
  bool _deleting = false;
  bool _paused = false;
  bool _holding = false;

  @override
  void initState() {
    super.initState();
    _notes = List<ChatStatusNote>.of(widget.notes);
    _bar = AnimationController(vsync: this, duration: const Duration(seconds: 6));
    _arm();
    _report(_notes.first);
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

  void _onBarDone() {
    if (!mounted || _paused || _holding) return;
    if (_bar.status != AnimationStatus.completed) return;
    _step(1);
  }

  void _arm() {
    _bar.forward(from: 0).whenComplete(_onBarDone);
  }

  /// Continues after a pause, a hold, or a sheet. stop() already finished the
  /// previous ticker, so the new run needs its own completion.
  void _continue() {
    if (!mounted || _paused || _holding) return;
    if (_bar.status == AnimationStatus.completed || _bar.isAnimating) return;
    _bar.forward().whenComplete(_onBarDone);
  }

  void _togglePause() {
    if (_paused) {
      setState(() => _paused = false);
      _continue();
      return;
    }
    setState(() => _paused = true);
    _bar.stop();
  }

  void _hold(bool down) {
    if (_holding == down) return;
    _holding = down;
    if (down) {
      _bar.stop();
      return;
    }
    _continue();
  }

  void _step(int by) {
    final next = _index + by;
    if (next < 0) {
      setState(() => _paused = false);
      _arm();
      return;
    }
    if (next >= _notes.length) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _index = next;
      _paused = false;
    });
    _report(_notes[next]);
    _arm();
  }

  Future<void> _reply(ChatStatusNote note) async {
    final name = note.name.trim().replaceFirst(RegExp(r'^@'), '');
    if (name.isEmpty || widget.own) return;
    _bar.stop();
    try {
      final opened = await ChatApi().openThread(name);
      if (!mounted) return;
      await context.push(
        '/chat/${opened.id}',
        extra: ChatThreadTarget(username: opened.username, name: opened.name),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(chatErrorText(error))),
      );
    }
    _continue();
  }

  Future<void> _delete(ChatStatusNote note) async {
    if (_deleting || note.id.isEmpty) return;
    _bar.stop();
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this status?'),
        content: const Text('It comes down for everyone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true || !mounted) {
      _continue();
      return;
    }
    setState(() => _deleting = true);
    try {
      await ChatApi().deleteStatus(note.id);
      if (!mounted) return;
      setState(() {
        _notes.removeWhere((item) => item.id == note.id);
        if (_index >= _notes.length) _index = _notes.length - 1;
        _deleting = false;
      });
      if (_notes.isEmpty) {
        Navigator.of(context).pop();
        return;
      }
      _report(_notes[_index]);
      _arm();
    } catch (error) {
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(chatErrorText(error))));
      _continue();
    }
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
    _continue();
  }

  @override
  void dispose() {
    _bar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final note = _notes[_index];
    final color = statusTone(note.id);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _step(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _step(1),
        const SingleActivator(LogicalKeyboardKey.space): _togglePause,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
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
                        for (var i = 0; i < _notes.length; i++)
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
                    if (widget.own)
                      IconButton(
                        tooltip: 'Delete',
                        onPressed: _deleting ? null : () => unawaited(_delete(note)),
                        icon: const Icon(Icons.delete_outline, color: Colors.white),
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
                    onLongPressStart: (_) => _hold(true),
                    onLongPressEnd: (_) => _hold(false),
                    onLongPressCancel: () => _hold(false),
                    onTapUp: (details) {
                      final width = MediaQuery.sizeOf(context).width;
                      _step(details.localPosition.dx < width / 3 ? -1 : 1);
                    },
                    child: Column(
                      children: [
                        if (note.image.isNotEmpty)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                              child: _StatusPhoto(key: ValueKey(note.id), id: note.id),
                            ),
                          )
                        else
                          const Spacer(),
                        if (note.text.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            child: Text(
                              note.text,
                              textAlign: TextAlign.center,
                              style: statusFontStyle(
                                note.font,
                                color: Colors.white,
                                size: note.image.isEmpty ? 28 : 20,
                              ),
                            ),
                          ),
                        if (note.image.isEmpty) const Spacer(),
                      ],
                    ),
                  ),
                ),
                if (firstWebUrl(note.text) case final link?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: StatusLinkCard(url: link),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      tooltip: 'Previous',
                      onPressed: () => _step(-1),
                      icon: const Icon(Icons.skip_previous_rounded, color: Colors.white),
                    ),
                    IconButton(
                      tooltip: _paused ? 'Play' : 'Pause',
                      onPressed: _togglePause,
                      icon: Icon(
                        _paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                        color: Colors.white,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Forward',
                      onPressed: () => _step(1),
                      icon: const Icon(Icons.skip_next_rounded, color: Colors.white),
                    ),
                    if (!widget.own)
                      IconButton(
                        tooltip: 'Reply',
                        onPressed: () => unawaited(_reply(note)),
                        icon: const Icon(Icons.reply_rounded, color: Colors.white),
                      ),
                  ],
                ),
                Text(
                  _paused ? 'Paused' : 'Hold the update to pause it',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
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
  int _font = 0;
  String _audience = 'all';
  bool _busy = false;
  Uint8List? _photo;

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

  Future<void> _pickPhoto() async {
    if (_busy) return;
    try {
      final picked = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Photos', extensions: ['jpg', 'jpeg', 'png']),
        ],
      );
      if (picked == null || !mounted) return;
      final raw = await picked.readAsBytes();
      final fitted = await fitChatImage(raw);
      if (!mounted) return;
      setState(() => _photo = fitted);
    } catch (error) {
      if (!mounted) return;
      final message = error is StateError ? error.message : chatErrorText(error);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    final photo = _photo;
    if ((text.isEmpty && photo == null) || _busy) return;
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
      if (photo != null) {
        await _api.postStatusImage(
          photo,
          caption: text,
          audience: _audience,
          allow: allow,
          deny: deny,
          font: _font,
        );
      } else {
        await _api.postStatus(
          text: text,
          audience: _audience,
          allow: allow,
          deny: deny,
          font: _font,
        );
      }
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

  Future<void> _pickEmoji() async {
    final emoji = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return EmojiPanel(onPick: (picked) => Navigator.pop(context, picked));
      },
    );
    if (emoji == null || !mounted) return;
    final value = _text.value;
    final text = value.text;
    final start = value.selection.start < 0 ? text.length : value.selection.start;
    final end = value.selection.end < 0 ? text.length : value.selection.end;
    final next = text.replaceRange(start, end, emoji);
    _text.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
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
              child: Column(
                children: [
                  if (_photo != null)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: Image.memory(_photo!, fit: BoxFit.contain),
                              ),
                            ),
                            Positioned(
                              top: 4,
                              right: 4,
                              child: IconButton(
                                tooltip: 'Remove photo',
                                onPressed: _busy ? null : () => setState(() => _photo = null),
                                icon: const Icon(Icons.close, color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Expanded(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: TextField(
                          controller: _text,
                          autofocus: _photo == null,
                          maxLength: 400,
                          maxLines: null,
                          textAlign: TextAlign.center,
                          style: statusFontStyle(_font, color: Colors.white, size: _photo == null ? 28 : 20),
                          cursorColor: Colors.white,
                          decoration: InputDecoration(
                            counterText: '',
                            border: InputBorder.none,
                            hintText: _photo == null ? 'Type a status' : 'Add a caption',
                            hintStyle: statusFontStyle(
                              _font,
                              color: Colors.white54,
                              size: _photo == null ? 28 : 20,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 72,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: statusFontChoices.length,
                separatorBuilder: (context, index) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final picked = index == _font;
                  final choice = statusFontChoices[index];
                  return ChoiceChip(
                    label: Text(
                      choice.name,
                      style: statusFontStyle(index, color: Colors.white, size: 14),
                    ),
                    selected: picked,
                    showCheckmark: false,
                    selectedColor: Colors.white24,
                    backgroundColor: Colors.white10,
                    side: BorderSide(color: picked ? Colors.white : Colors.white24),
                    labelStyle: const TextStyle(color: Colors.white),
                    onSelected: _busy ? null : (_) => setState(() => _font = index),
                  );
                },
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
                  IconButton(
                    tooltip: 'Photo',
                    onPressed: _busy ? null : () => unawaited(_pickPhoto()),
                    icon: const Icon(Icons.photo_outlined, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: 'Emoji',
                    onPressed: _busy ? null : _pickEmoji,
                    icon: const Icon(Icons.emoji_emotions_outlined, color: Colors.white),
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

class _StatusPhoto extends StatefulWidget {
  const _StatusPhoto({super.key, required this.id});

  final String id;

  @override
  State<_StatusPhoto> createState() => _StatusPhotoState();
}

class _StatusPhotoState extends State<_StatusPhoto> {
  Uint8List? _bytes;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final bytes = await ChatApi().statusImage(widget.id);
      if (!mounted) return;
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
    if (bytes != null && bytes.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Image.memory(bytes, fit: BoxFit.contain),
      );
    }
    if (_failed) {
      return const Center(
        child: Text(
          'Photo could not be opened.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70),
        ),
      );
    }
    return const Center(child: CircularProgressIndicator(color: Colors.white));
  }
}
