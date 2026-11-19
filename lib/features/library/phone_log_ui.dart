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
                    'Each entry shows the time and the details. After the owner says yes, a notification includes its title and the words on it.',
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.35),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: phones.isEmpty
                        ? Text(
                            'Plug in a phone with Social Save open and USB debugging allowed.',
                            style: theme.textTheme.bodyMedium,
                          )
                        : ListView(
                            children: [
                              for (final phone in phones) ...[
                                _PhoneBlock(phone: phone),
                              ],
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

class _PhoneBlock extends StatelessWidget {
  const _PhoneBlock({required this.phone});

  final PluggedPhoneLog phone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entries = [for (final line in _newestFirst(phone.lines)) presentPhoneLog(line)];
    final rows = _withDays(entries);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.smartphone_rounded, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(phone.name, style: theme.textTheme.titleMedium)),
          ],
        ),
        if (entries.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final chip in _counts(entries))
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(chip),
                  padding: EdgeInsets.zero,
                  labelStyle: theme.textTheme.labelMedium,
                ),
            ],
          ),
        ],
        if (phone.problem.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(phone.problem, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error)),
        ],
        if (entries.isEmpty && phone.problem.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 8, bottom: 12),
            child: Text('This phone has not written a log yet.'),
          ),
        for (final row in rows)
          if (row.day != null)
            Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 6),
              child: Text(row.day!, style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary)),
            )
          else
            _LogCard(entry: row.entry!),
        const SizedBox(height: 8),
      ],
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

List<String> _counts(List<PhoneLogEntry> entries) {
  var notes = 0;
  var apps = 0;
  var screen = 0;
  var locks = 0;
  for (final entry in entries) {
    switch (entry.kind) {
      case 'notification':
        notes++;
      case 'opened':
      case 'used':
        apps++;
      case 'screen':
        screen++;
      case 'lock':
        locks++;
    }
  }
  final chips = <String>[];
  if (notes > 0) chips.add('$notes ${notes == 1 ? 'notification' : 'notifications'}');
  if (apps > 0) chips.add('$apps ${apps == 1 ? 'app' : 'apps'}');
  if (screen > 0) chips.add('$screen screen');
  if (locks > 0) chips.add('$locks ${locks == 1 ? 'lock' : 'locks'}');
  return chips;
}

class _LogCard extends StatelessWidget {
  const _LogCard({required this.entry});

  final PhoneLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = _tint(scheme, entry.kind);
    final hint = entry.detail == 'App name only' || entry.detail.startsWith('App name only');
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
