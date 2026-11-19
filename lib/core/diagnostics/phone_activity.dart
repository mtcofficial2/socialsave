import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/diagnostics/plain_log.dart';
import 'package:social_save/core/platform/plat.dart';

/// Social Save's own actions, plus the other apps this phone used.
class PhoneActivity {
  PhoneActivity._();

  static const _channel = MethodChannel('socialsave/media');
  static const _consentKey = 'socialsave_full_log';
  static var _askedUsage = false;
  static var _askedNotes = false;
  static var _prompting = false;
  static String _screen = '';

  /// Yes or no from the phone's owner. Null means they have not answered.
  static Future<bool?> Function()? debugConsent;

  /// Shows the Yes / Not now question. Assigned while the app is starting.
  static Future<bool?> Function()? prompt;

  /// Records a screen change once. Tab changes and pushed pages both call this.
  static void sawScreen(String path) {
    final sentence = PlainLog.screenSentence(path);
    if (sentence == null || sentence == _screen) return;
    _screen = sentence;
    PlainLog.note(sentence);
  }

  static void debugReset() {
    _askedUsage = false;
    _askedNotes = false;
    _prompting = false;
    _screen = '';
    debugConsent = null;
    prompt = null;
  }

  /// True when the owner allowed the fuller log, false when they said not now.
  static Future<bool?> consent() async {
    final override = debugConsent;
    if (override != null) return override();
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString(_consentKey);
      if (value == 'yes') return true;
      if (value == 'no') return false;
    } catch (_) {}
    return null;
  }

  static Future<void> setConsent(bool yes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_consentKey, yes ? 'yes' : 'no');
    if (!Plat.isAndroid) return;
    try {
      if (yes) {
        _askedNotes = true;
        await _channel.invokeMethod<void>('openNotificationAccessIfNeeded');
      } else {
        await _channel.invokeMethod<void>('clearPhoneNotes');
      }
    } catch (_) {}
  }

  /// Real time for a log stamp. Usage lines end in Z. Older plain-log lines do not.
  static DateTime instant(String raw) {
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return parsed.toUtc();
  }

  /// Lines for the computer: what Social Save did, then what the phone used.
  static Future<List<Map<String, String>>> forCable() async {
    await PlainLog.load();
    final lines = <Map<String, String>>[
      for (final line in PlainLog.lines) line.toJson(),
    ];
    final allowed = await consent();
    final track = Plat.isAndroid || debugConsent != null;
    if (track && allowed == null && debugConsent == null) {
      unawaited(_promptOnce());
    }
    lines.addAll(await _usage(full: allowed == true));
    if (track && allowed != true) {
      lines.add({
        'at': DateTime.now().toUtc().toIso8601String(),
        'kind': 'note',
        'title': allowed == false ? 'Fuller log is off' : 'Waiting for the owner',
        'detail': allowed == false
            ? 'They can turn it on in Settings, under Fuller phone log.'
            : 'The owner has not tapped Yes yet.',
        'text': allowed == false
            ? 'The owner of this phone left the fuller log off. They can turn it on in Settings.'
            : 'The owner of this phone has not allowed the fuller log yet.',
      });
    }
    lines.sort((a, b) => instant(a['at'] ?? '').compareTo(instant(b['at'] ?? '')));
    final cap = allowed == true ? 500 : 250;
    if (lines.length > cap) return lines.sublist(lines.length - cap);
    return lines;
  }

  static Future<void> _promptOnce() async {
    final ask = prompt;
    if (_prompting || ask == null || !Plat.isAndroid) return;
    _prompting = true;
    try {
      final answer = await ask();
      if (answer == null) {
        _prompting = false;
        return;
      }
      await setConsent(answer);
    } catch (_) {
      _prompting = false;
    }
  }

  static Future<List<Map<String, String>>> _usage({required bool full}) async {
    if (!Plat.isAndroid) return const [];
    try {
      final raw = await _channel.invokeMethod<dynamic>('phoneUsage', {'full': full});
      if (raw is! Map) return const [];
      final allowed = raw['allowed'] == true;
      if (!allowed) {
        if (!_askedUsage) {
          _askedUsage = true;
          await _channel.invokeMethod<void>('openUsageAccess');
        }
        return [
          {
            'at': DateTime.now().toUtc().toIso8601String(),
            'kind': 'note',
            'title': 'Usage access is off',
            'detail': 'Allow Social Save under Usage access on this phone to see the other apps it uses.',
            'text': 'Allow Social Save under Usage access on this phone to see the other apps it uses.',
          },
        ];
      }
      if (full && raw['notesAllowed'] != true && !_askedNotes) {
        _askedNotes = true;
        await _channel.invokeMethod<void>('openNotificationAccessIfNeeded');
      }
      final rows = raw['lines'];
      if (rows is! List) return const [];
      final lines = <Map<String, String>>[];
      for (final row in rows) {
        if (row is! Map) continue;
        final text = '${row['text'] ?? ''}'.trim();
        if (text.isEmpty) continue;
        final line = <String, String>{'at': '${row['at'] ?? ''}', 'text': text};
        for (final key in const ['kind', 'title', 'detail']) {
          final value = '${row[key] ?? ''}'.trim();
          if (value.isNotEmpty) line[key] = value;
        }
        lines.add(line);
      }
      return lines;
    } catch (_) {
      return const [];
    }
  }
}
