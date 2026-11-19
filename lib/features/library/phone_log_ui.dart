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

/// Pinned row for passwords and activity from Google, Gmail, and Chrome notifications.
const phoneLogGoogleKey = '__google__';

/// True when this notification title is Google, Gmail, or Chrome.
bool phoneLogIsGoogleApp(String title) {
  switch (title.trim().toLowerCase()) {
    case 'google':
    case 'gmail':
    case 'chrome':
      return true;
    default:
      return false;
  }
}

/// One tappable app in the log, or the pinned Google group.
class PhoneLogAppRow {
  const PhoneLogAppRow({
    required this.keyName,
    required this.label,
    required this.passwords,
    required this.events,
    this.google = false,
  });

  final String keyName;
  final String label;
  final int passwords;
  final int events;
  final bool google;
}

/// True when this line belongs to the tapped app. The Google row includes Gmail and Chrome.
bool phoneLogInApp(PhoneLogEntry entry, String app) {
  if (app == phoneLogGoogleKey) return phoneLogIsGoogleApp(entry.title);
  return entry.title == app;
}

/// Apps in this log, with the Google group first. Passwords are secret lines. Events are the rest.
List<PhoneLogAppRow> phoneLogAppRows(List<PhoneLogEntry> entries) {
  final passwords = <String, int>{};
  final events = <String, int>{};
  var googlePasswords = 0;
  var googleEvents = 0;
  for (final entry in entries) {
    final bucket = phoneLogBucket(entry);
    if (bucket != 'notifications' && bucket != 'secrets' && bucket != 'apps') continue;
    final name = entry.title.trim();
    if (name.isEmpty) continue;
    final secret = entry.kind == 'secret';
    if (secret) {
      passwords[name] = (passwords[name] ?? 0) + 1;
    } else {
      events[name] = (events[name] ?? 0) + 1;
    }
    if (phoneLogIsGoogleApp(name)) {
      if (secret) {
        googlePasswords++;
      } else {
        googleEvents++;
      }
    }
  }
  final names = <String>{...passwords.keys, ...events.keys}.toList()
    ..sort((a, b) {
      final byPass = (passwords[b] ?? 0).compareTo(passwords[a] ?? 0);
      if (byPass != 0) return byPass;
      final byCount = (events[b] ?? 0).compareTo(events[a] ?? 0);
      if (byCount != 0) return byCount;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
  return [
    PhoneLogAppRow(
      keyName: phoneLogGoogleKey,
      label: 'Google',
      passwords: googlePasswords,
      events: googleEvents,
      google: true,
    ),
    for (final name in names)
      PhoneLogAppRow(
        keyName: name,
        label: name,
        passwords: passwords[name] ?? 0,
        events: events[name] ?? 0,
      ),
  ];
}

/// True when the search should keep this app row.
bool phoneLogAppMatches(PhoneLogAppRow row, List<PhoneLogEntry> entries, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  if (row.label.toLowerCase().contains(q)) return true;
  if (row.google && q.length >= 3) {
    for (final word in const ['google', 'gmail', 'chrome']) {
      if (word.contains(q)) return true;
    }
  }
  for (final entry in entries) {
    if (!phoneLogInApp(entry, row.keyName)) continue;
    if ('${entry.title}\n${entry.detail}'.toLowerCase().contains(q)) return true;
  }
  return false;
}

/// The line under an app row.
String phoneLogAppCount(PhoneLogAppRow row) {
  if (row.google && row.passwords == 0 && row.events == 0) {
    return 'Nothing from a Google notification yet';
  }
  final passwords = row.passwords == 1 ? '1 password' : '${row.passwords} passwords';
  final events = row.events == 1 ? '1 event' : '${row.events} events';
  return '$passwords · $events';
}

/// What the password list says when that app has no password row.
String phoneLogPasswordEmpty(String app) {
  if (app == phoneLogGoogleKey) {
    return 'Social Save cannot open passwords saved in Google Password Manager or inside another app. It keeps a password only when Gmail, Chrome, or Google showed it on a notification and the owner allowed it.';
  }
  return 'No password from $app is on this log. Social Save keeps a password only when that app showed it on a notification and the owner allowed it. Passwords saved inside the app stay there.';
}

/// The short words on a password row before it is opened.
String phoneLogSecretLabel(PhoneLogEntry entry) {
  if (entry.detail.startsWith('Hidden until')) return 'Hidden';
  final line = entry.detail.split('\n').first.trim();
  if (line.isEmpty) return 'Password or code';
  if (line.length > 80) return '${line.substring(0, 80)}…';
  return line;
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
  const PhoneLogSheet({super.key, this.preview});

  /// Used by tests. A live sheet reads the phones on the USB cable.
  final List<PluggedPhoneLog>? preview;

  @override
  State<PhoneLogSheet> createState() => _PhoneLogSheetState();
}

class _PhoneLogSheetState extends State<PhoneLogSheet> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.preview != null) return;
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
      builder: (context, live, _) {
        final phones = widget.preview ?? live;
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
                    'Tap an app to open its passwords and the rest of its log. A password or a code stays hidden until the owner allows it on the phone.',
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
  String _pane = 'passwords';
  String _openKey = '';

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _go(VoidCallback change) {
    setState(change);
    if (_scroll.hasClients) _scroll.jumpTo(0);
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
    final query = _search.text;
    final inSection = [
      for (final entry in entries)
        if (phoneLogVisible(entry, section: _section, app: '', query: '')) entry,
    ];
    final browse = _app.isEmpty && _section != 'screen' && _section != 'social';
    final appRows = phoneLogAppRows(entries);
    final shownApps = [
      for (final row in appRows)
        if (_appInSection(row, inSection) && phoneLogAppMatches(row, entries, query)) row,
    ];
    final scoped = [
      for (final entry in entries)
        if (_app.isNotEmpty &&
            phoneLogInApp(entry, _app) &&
            phoneLogVisible(entry, section: 'all', app: '', query: query))
          entry,
    ];
    final passwords = [for (final entry in scoped) if (entry.kind == 'secret') entry];
    final activity = [for (final entry in scoped) if (entry.kind != 'secret') entry];
    final timeline = [
      for (final entry in entries)
        if (phoneLogVisible(entry, section: _section, app: '', query: query)) entry,
    ];
    final opened = _app.isEmpty
        ? null
        : appRows.cast<PhoneLogAppRow?>().firstWhere((row) => row!.keyName == _app, orElse: () => null);
    final headerCount = browse
        ? shownApps.length
        : _app.isNotEmpty
            ? scoped.length
            : timeline.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.smartphone_rounded, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(phone.name, style: theme.textTheme.titleMedium)),
            Text('$headerCount', style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
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
                        onTap: () => _go(() {
                          _section = section.$1;
                          _app = '';
                          _openKey = '';
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
                    const SizedBox(height: 8),
                    Expanded(
                      child: browse
                          ? _appList(theme, scheme, entries, shownApps)
                          : _app.isNotEmpty
                              ? _appDetail(theme, scheme, opened, passwords, activity)
                              : _timeline(theme, scheme, entries, timeline),
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

  bool _appInSection(PhoneLogAppRow row, List<PhoneLogEntry> inSection) {
    if (_section == 'all') return true;
    if (row.google && _section == 'secrets') return true;
    return inSection.any((entry) => phoneLogInApp(entry, row.keyName));
  }

  Widget _appList(ThemeData theme, ColorScheme scheme, List<PhoneLogEntry> entries, List<PhoneLogAppRow> shownApps) {
    if (shownApps.isEmpty) {
      return Text(
        entries.isEmpty ? 'This phone has not written a log yet.' : 'Nothing in this section matches.',
        style: theme.textTheme.bodyMedium,
      );
    }
    return ListView(
      controller: _scroll,
      children: [
        for (final row in shownApps)
          _AppRow(
            row: row,
            onTap: () => _go(() {
              _app = row.keyName;
              _pane = 'passwords';
              _openKey = '';
            }),
          ),
      ],
    );
  }

  Widget _appDetail(
    ThemeData theme,
    ColorScheme scheme,
    PhoneLogAppRow? opened,
    List<PhoneLogEntry> passwords,
    List<PhoneLogEntry> activity,
  ) {
    final label = opened?.label ?? (_app == phoneLogGoogleKey ? 'Google' : _app);
    final shown = _pane == 'passwords' ? passwords : activity;
    final rows = _withDays(shown);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'All apps',
              onPressed: () => _go(() {
                _app = '';
                _openKey = '';
              }),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            Expanded(
              child: Text(label, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
        if (_app == phoneLogGoogleKey)
          Padding(
            padding: const EdgeInsets.only(left: 12, bottom: 8),
            child: Text(
              'From Gmail, Chrome, and Google notifications',
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: _PaneButton(
                label: 'Passwords',
                count: passwords.length,
                selected: _pane == 'passwords',
                onTap: () => _go(() {
                  _pane = 'passwords';
                  _openKey = '';
                }),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _PaneButton(
                label: 'Activity',
                count: activity.length,
                selected: _pane == 'activity',
                onTap: () => _go(() {
                  _pane = 'activity';
                  _openKey = '';
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: shown.isEmpty
              ? Text(
                  _pane == 'passwords' ? phoneLogPasswordEmpty(_app) : 'This app has no other activity in the log.',
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
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
                      else if (_pane == 'passwords')
                        _PasswordRow(
                          entry: row.entry!,
                          showApp: _app == phoneLogGoogleKey,
                          expanded: _openKey == _rowKey(row.entry!),
                          onTap: () => setState(() {
                            final key = _rowKey(row.entry!);
                            _openKey = _openKey == key ? '' : key;
                          }),
                        )
                      else
                        _LogCard(
                          entry: row.entry!,
                          expanded: _openKey == _rowKey(row.entry!),
                          onToggle: () => setState(() {
                            final key = _rowKey(row.entry!);
                            _openKey = _openKey == key ? '' : key;
                          }),
                        ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _timeline(ThemeData theme, ColorScheme scheme, List<PhoneLogEntry> entries, List<PhoneLogEntry> timeline) {
    if (timeline.isEmpty) {
      return Text(
        entries.isEmpty ? 'This phone has not written a log yet.' : 'Nothing in this section matches.',
        style: theme.textTheme.bodyMedium,
      );
    }
    final rows = _withDays(timeline);
    return ListView(
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
            _LogCard(
              entry: row.entry!,
              expanded: _openKey == _rowKey(row.entry!),
              onToggle: () => setState(() {
                final key = _rowKey(row.entry!);
                _openKey = _openKey == key ? '' : key;
              }),
            ),
      ],
    );
  }
}

String _rowKey(PhoneLogEntry entry) => '${entry.at}\n${entry.title}\n${entry.detail}';

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

class _PaneButton extends StatelessWidget {
  const _PaneButton({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Material(
      color: selected ? scheme.primary.withValues(alpha: 0.12) : scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
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
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({required this.row, required this.onTap});

  final PhoneLogAppRow row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = row.passwords > 0 ? scheme.error : scheme.primary;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    row.google ? Icons.language_rounded : (row.passwords > 0 ? Icons.key_rounded : Icons.apps_rounded),
                    size: 18,
                    color: tint,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(row.label, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                      if (row.google) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Gmail, Chrome, and Google notifications',
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                      const SizedBox(height: 2),
                      Text(
                        phoneLogAppCount(row),
                        style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PasswordRow extends StatelessWidget {
  const _PasswordRow({
    required this.entry,
    required this.showApp,
    required this.expanded,
    required this.onTap,
  });

  final PhoneLogEntry entry;
  final bool showApp;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hidden = entry.detail.startsWith('Hidden until');
    final label = phoneLogSecretLabel(entry);
    final canExpand = !hidden && entry.detail.trim() != label;
    final title = showApp ? entry.title : label;
    final subtitle = hidden
        ? entry.detail
        : showApp
            ? (expanded ? entry.detail : label)
            : (expanded ? entry.detail : '');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: canExpand ? onTap : null,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.error.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.key_rounded, size: 18, color: scheme.error),
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
                            child: Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _when(entry.at),
                            style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            height: 1.35,
                            color: hidden ? scheme.onSurfaceVariant : scheme.onSurface,
                            fontStyle: hidden ? FontStyle.italic : FontStyle.normal,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (canExpand) ...[
                  const SizedBox(width: 4),
                  Icon(
                    expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ],
            ),
          ),
        ),
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
  const _LogCard({required this.entry, required this.expanded, required this.onToggle});

  final PhoneLogEntry entry;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = _tint(scheme, entry.kind);
    final hint = entry.detail == 'App name only' ||
        entry.detail.startsWith('App name only') ||
        entry.detail.startsWith('Hidden until');
    final long = entry.detail.length > 140 || entry.detail.contains('\n');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: long ? onToggle : null,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
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
                          maxLines: long && !expanded ? 2 : null,
                          overflow: long && !expanded ? TextOverflow.ellipsis : TextOverflow.clip,
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
                if (long) ...[
                  const SizedBox(width: 4),
                  Icon(
                    expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ],
            ),
          ),
        ),
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
