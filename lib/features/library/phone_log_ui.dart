import 'dart:async';

import 'package:flutter/material.dart';
import 'package:social_save/core/diagnostics/phone_activity.dart';
import 'package:social_save/features/library/usb_link.dart';

/// Opens the log of every Social Save phone on the USB cable.
Future<void> showPhoneLog(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => const FractionallySizedBox(
      heightFactor: 0.9,
      child: PhoneLogSheet(),
    ),
  );
}

/// How one log line is shown: a title, and the details under it.
class PhoneLogEntry {
  const PhoneLogEntry({
    required this.kind,
    required this.title,
    required this.detail,
    required this.at,
  });

  final String kind;
  final String title;
  final String detail;
  final String at;
}

/// Turns a cable line into a title and the words that belong under it.
PhoneLogEntry presentPhoneLog(PhoneLogLine line) {
  final kind = line.kind.trim();
  final title = line.title.trim();
  var detail = line.detail.trim();
  if (kind == 'secret' || detail.startsWith('Hidden. This notification')) {
    final hidden = detail.startsWith('Hidden. This notification') || detail.isEmpty;
    return PhoneLogEntry(
      kind: 'secret',
      title: title.isEmpty ? 'Password or code' : title,
      detail: hidden ? 'Hidden until the owner allows passwords and codes.' : detail,
      at: line.at,
    );
  }
  if (kind.isNotEmpty && title.isNotEmpty) {
    if (detail == title) detail = '';
    return PhoneLogEntry(kind: kind, title: title, detail: detail, at: line.at);
  }
  final text = line.text.trim();
  final note = RegExp(r'^A notification arrived from (.+)\.$').firstMatch(text);
  if (note != null) {
    return PhoneLogEntry(
      kind: 'notification',
      title: note.group(1)!,
      detail: 'App name only',
      at: line.at,
    );
  }
  final many = RegExp(r'^(\d+) notifications arrived from (.+)\.$').firstMatch(text);
  if (many != null) {
    return PhoneLogEntry(
      kind: 'notification',
      title: many.group(2)!,
      detail: 'App name only · ${many.group(1)} notifications',
      at: line.at,
    );
  }
  final opened = RegExp(r'^Opened (.+)\.$').firstMatch(text);
  if (opened != null) {
    return PhoneLogEntry(kind: 'opened', title: opened.group(1)!, detail: 'Opened', at: line.at);
  }
  final used = RegExp(r'^Used (.+) for (.+)\.$').firstMatch(text);
  if (used != null) {
    return PhoneLogEntry(
      kind: 'used',
      title: used.group(1)!,
      detail: 'Used for ${used.group(2)}',
      at: line.at,
    );
  }
  return PhoneLogEntry(kind: _guessKind(text), title: text, detail: '', at: line.at);
}

/// All, notifications, passwords, apps, screen, or Social Save.
String phoneLogBucket(PhoneLogEntry entry) {
  if (entry.kind == 'secret') return 'secrets';
  switch (entry.kind) {
    case 'notification':
      return 'notifications';
    case 'opened':
    case 'used':
      return 'apps';
    case 'screen':
    case 'lock':
    case 'power':
      return 'screen';
    default:
      return 'social';
  }
}

/// True when this line belongs in the section, the app, and the search.
bool phoneLogVisible(
  PhoneLogEntry entry, {
  required String section,
  required String app,
  required String query,
}) {
  if (section != 'all' && phoneLogBucket(entry) != section) return false;
  if (app.isNotEmpty && entry.title != app) return false;
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return '${entry.title}\n${entry.detail}'.toLowerCase().contains(q);
}

/// App names in this set, most frequent first.
List<String> phoneLogApps(List<PhoneLogEntry> entries) {
  final counts = <String, int>{};
  for (final entry in entries) {
    final bucket = phoneLogBucket(entry);
    if (bucket != 'notifications' && bucket != 'secrets' && bucket != 'apps') continue;
    final name = entry.title.trim();
    if (name.isEmpty) continue;
    counts[name] = (counts[name] ?? 0) + 1;
  }
  final names = counts.keys.toList()
    ..sort((a, b) {
      final byCount = counts[b]!.compareTo(counts[a]!);
      if (byCount != 0) return byCount;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
  if (names.length > 16) return names.sublist(0, 16);
  return names;
}

String _guessKind(String text) {
  final lower = text.toLowerCase();
  if (lower.contains('notification')) return 'notification';
  if (lower.contains('screen')) return 'screen';
  if (lower.contains('locked') || lower.contains('unlocked')) return 'lock';
  if (lower.contains('turned on') || lower.contains('shut down')) return 'power';
  if (lower.contains('owner of this phone') || lower.startsWith('allow ')) return 'note';
  return 'social';
}

class PhoneLogSheet extends StatefulWidget {
  const PhoneLogSheet({super.key});

  @override
  State<PhoneLogSheet> createState() => _PhoneLogSheetState();
}

class _PhoneLogSheetState extends State<PhoneLogSheet> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(UsbLink.refreshDeviceLogs());
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      unawaited(UsbLink.refreshDeviceLogs());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ValueListenableBuilder<List<PluggedPhoneLog>>(
      valueListenable: UsbLink.deviceLogs,
      builder: (context, phones, _) {
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Phone log', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    'Pick a section, an app, or search. A notification shows its title and words. A password or a code stays hidden until the owner allows it on the phone.',
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.35),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: phones.isEmpty
                        ? Text(
                            'Plug in a phone with Social Save open and USB debugging allowed.',
                            style: theme.textTheme.bodyMedium,
                          )
                        : Column(
                            children: [
                              for (var i = 0; i < phones.length; i++)
                                Expanded(
                                  child: _PhoneBlock(key: ValueKey(phones[i].serial), phone: phones[i]),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PhoneBlock extends StatefulWidget {
  const _PhoneBlock({super.key, required this.phone});

  final PluggedPhoneLog phone;

  @override
  State<_PhoneBlock> createState() => _PhoneBlockState();
}

class _PhoneBlockState extends State<_PhoneBlock> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  String _section = 'all';
  String _app = '';

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final phone = widget.phone;
    final entries = [for (final line in _newestFirst(phone.lines)) presentPhoneLog(line)];
    final counts = <String, int>{};
    for (final entry in entries) {
      final bucket = phoneLogBucket(entry);
      counts[bucket] = (counts[bucket] ?? 0) + 1;
    }
    final inSection = [
      for (final entry in entries)
        if (phoneLogVisible(entry, section: _section, app: '', query: _search.text)) entry,
    ];
    final apps = phoneLogApps(inSection);
    final app = apps.contains(_app) ? _app : '';
    final shown = [
      for (final entry in inSection)
        if (app.isEmpty || entry.title == app) entry,
    ];
    final rows = _withDays(shown);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.smartphone_rounded, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(phone.name, style: theme.textTheme.titleMedium)),
            Text('${shown.length}', style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
        if (phone.problem.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(phone.problem, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error)),
        ],
        const SizedBox(height: 8),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 156,
                child: ListView(
                  children: [
                    for (final section in _sections)
                      _SectionButton(
                        label: section.$2,
                        icon: section.$3,
                        count: section.$1 == 'all' ? entries.length : (counts[section.$1] ?? 0),
                        selected: _section == section.$1,
                        onTap: () => setState(() {
                          _section = section.$1;
                          _app = '';
                        }),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Search the log',
                        prefixIcon: Icon(Icons.search_rounded),
                      ),
                    ),
                    if (apps.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 36,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            _AppChip(
                              label: 'All apps',
                              selected: app.isEmpty,
                              onTap: () => setState(() => _app = ''),
                            ),
                            for (final name in apps)
                              _AppChip(
                                label: name,
                                selected: app == name,
                                onTap: () => setState(() => _app = name),
                              ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Expanded(
                      child: shown.isEmpty
                          ? Text(
                              entries.isEmpty
                                  ? 'This phone has not written a log yet.'
                                  : 'Nothing in this section matches.',
                              style: theme.textTheme.bodyMedium,
                            )
                          : ListView(
                              controller: _scroll,
                              children: [
                                for (final row in rows)
                                  if (row.day != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8, bottom: 6),
                                      child: Text(
                                        row.day!,
                                        style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary),
                                      ),
                                    )
                                  else
                                    _LogCard(entry: row.entry!),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

const _sections = <(String, String, IconData)>[
  ('all', 'All', Icons.list_rounded),
  ('notifications', 'Notifications', Icons.notifications_rounded),
  ('secrets', 'Passwords', Icons.key_rounded),
  ('apps', 'Apps', Icons.apps_rounded),
  ('screen', 'Screen', Icons.phone_android_rounded),
  ('social', 'Social Save', Icons.notes_rounded),
];

class _SectionButton extends StatelessWidget {
  const _SectionButton({
    required this.label,
    required this.icon,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? scheme.primary.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: color,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                Text('$count', style: theme.textTheme.labelMedium?.copyWith(color: color)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AppChip extends StatelessWidget {
  const _AppChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
        selectedColor: scheme.primary.withValues(alpha: 0.16),
      ),
    );
  }
}

const _cableLine = 'A computer connected over the USB cable.';

/// Newest real time first. Repeated cable lines keep only the latest one.
List<PhoneLogLine> _newestFirst(List<PhoneLogLine> lines) {
  final sorted = [...lines]..sort((a, b) => PhoneActivity.instant(b.at).compareTo(PhoneActivity.instant(a.at)));
  final kept = <PhoneLogLine>[];
  var sawCable = false;
  for (final line in sorted) {
    if (line.text == _cableLine) {
      if (sawCable) continue;
      sawCable = true;
    }
    kept.add(line);
  }
  return kept;
}

class _DayRow {
  const _DayRow.day(this.day) : entry = null;
  const _DayRow.entry(this.entry) : day = null;

  final String? day;
  final PhoneLogEntry? entry;
}

List<_DayRow> _withDays(List<PhoneLogEntry> entries) {
  final rows = <_DayRow>[];
  String? last;
  for (final entry in entries) {
    final day = _dayLabel(entry.at);
    if (day.isNotEmpty && day != last) {
      rows.add(_DayRow.day(day));
      last = day;
    }
    rows.add(_DayRow.entry(entry));
  }
  return rows;
}

class _LogCard extends StatelessWidget {
  const _LogCard({required this.entry});

  final PhoneLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = _tint(scheme, entry.kind);
    final hint = entry.detail == 'App name only' ||
        entry.detail.startsWith('App name only') ||
        entry.detail.startsWith('Hidden until');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(_icon(entry.kind), size: 18, color: tint),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        entry.title,
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _when(entry.at),
                      style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
                if (entry.detail.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    entry.detail,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      height: 1.35,
                      color: hint ? scheme.onSurfaceVariant : scheme.onSurface,
                      fontStyle: hint ? FontStyle.italic : FontStyle.normal,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

IconData _icon(String kind) {
  switch (kind) {
    case 'notification':
      return Icons.notifications_rounded;
    case 'secret':
      return Icons.key_rounded;
    case 'opened':
      return Icons.open_in_new_rounded;
    case 'used':
      return Icons.apps_rounded;
    case 'screen':
      return Icons.phone_android_rounded;
    case 'lock':
      return Icons.lock_rounded;
    case 'power':
      return Icons.power_settings_new_rounded;
    case 'note':
      return Icons.info_outline_rounded;
    default:
      return Icons.notes_rounded;
  }
}

Color _tint(ColorScheme scheme, String kind) {
  switch (kind) {
    case 'notification':
      return scheme.tertiary;
    case 'secret':
      return scheme.error;
    case 'lock':
      return scheme.secondary;
    case 'note':
      return scheme.error;
    case 'screen':
    case 'power':
      return scheme.secondary;
    default:
      return scheme.primary;
  }
}

String _dayLabel(String iso) {
  final time = DateTime.tryParse(iso)?.toLocal();
  if (time == null) return '';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(time.year, time.month, time.day);
  if (day == today) return 'Today';
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${months[time.month - 1]} ${time.day}';
}

String _when(String iso) {
  final time = DateTime.tryParse(iso)?.toLocal();
  if (time == null) return '';
  final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
  final minute = time.minute.toString().padLeft(2, '0');
  final half = time.hour >= 12 ? 'PM' : 'AM';
  return '$hour:$minute $half';
}
