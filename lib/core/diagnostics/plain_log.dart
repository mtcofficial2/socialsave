import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One sentence this device wrote for a person to read.
class PlainLine {
  const PlainLine(this.at, this.text);

  final DateTime at;
  final String text;

  Map<String, String> toJson() => {'at': at.toIso8601String(), 'text': text};
}

/// A short history of what Social Save did, in plain English.
///
/// The phone keeps this on the device. A computer with Social Save can read
/// it over the USB cable. It never stores passwords, tokens, or message text.
class PlainLog {
  PlainLog._();

  static const keep = 200;
  static const _key = 'socialsave_plain_log';
  static final List<PlainLine> _lines = [];
  static String _last = '';
  static DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  static bool _loadStarted = false;
  static Future<void>? _loadDone;
  static Timer? _saveTimer;

  static List<PlainLine> get lines => List<PlainLine>.unmodifiable(_lines);

  static Future<void> load() {
    if (_loadStarted) return _loadDone ?? Future<void>.value();
    _loadStarted = true;
    _loadDone = _read();
    return _loadDone!;
  }

  static void note(String text) {
    final clean = _clean(text);
    if (clean == null) return;
    final now = DateTime.now();
    if (clean == _last && now.difference(_lastAt) < const Duration(seconds: 45)) {
      return;
    }
    _last = clean;
    _lastAt = now;
    _lines.add(PlainLine(now, clean));
    if (_lines.length > keep) {
      _lines.removeRange(0, _lines.length - keep);
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_write());
    });
  }

  /// A Social Save screen, as a sentence. Unknown paths are skipped.
  static String? screenSentence(String path) {
    final clean = path.split('?').first;
    if (clean.isEmpty || clean == '/') return 'Opened Home.';
    if (clean == '/library') return 'Opened the library.';
    if (clean.startsWith('/downloads/')) return 'Opened a saved file.';
    if (clean == '/downloads') return 'Opened downloads.';
    if (clean == '/settings') return 'Opened Settings.';
    if (clean == '/chat') return 'Opened chats.';
    if (clean.startsWith('/chat/')) return 'Opened a conversation.';
    if (clean == '/player') return 'Opened the player.';
    if (clean == '/preview') return 'Opened a preview.';
    if (clean == '/share') return 'Opened sharing.';
    if (clean == '/music') return 'Opened music.';
    if (clean == '/status') return 'Opened status.';
    if (clean == '/browse') return 'Opened the browser.';
    if (clean == '/playlist') return 'Opened a set of links.';
    if (clean.startsWith('/progress/')) return 'Opened a download.';
    if (clean == '/about') return 'Opened About.';
    if (clean.startsWith('/legal/')) return 'Opened a legal page.';
    if (clean == '/background-detect') return 'Opened link detection.';
    return null;
  }

  /// Turns a known diagnostic line into a sentence. Unknown lines are dropped.
  static String? plainEnglish(String? raw) {
    if (raw == null) return null;
    final message = raw.trim();
    if (!message.startsWith('[') || _secret(message)) return null;
    final end = message.indexOf(']');
    if (end < 2 || end > 24) return null;
    final tag = message.substring(1, end);
    final rest = message.substring(end + 1).trim();
    if (rest.isEmpty || _secret(rest)) return null;
    return switch (tag) {
      'session' => _session(rest),
      'usb' => _usb(rest),
      'hotspot' => _hotspot(rest),
      'tray' => _tray(rest),
      _ => null,
    };
  }

  static void fromDebug(String? raw) {
    final sentence = plainEnglish(raw);
    if (sentence != null) note(sentence);
  }

  static void debugReset() {
    _saveTimer?.cancel();
    _lines.clear();
    _last = '';
    _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  static String? _clean(String text) {
    var clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty || _secret(clean)) return null;
    if (clean.length > 180) clean = '${clean.substring(0, 177)}…';
    if (!clean.endsWith('.') && !clean.endsWith('!') && !clean.endsWith('?')) {
      clean = '$clean.';
    }
    return clean;
  }

  static bool _secret(String text) {
    final lower = text.toLowerCase();
    return lower.contains('password') ||
        lower.contains('token') ||
        lower.contains('bearer') ||
        lower.contains('authorization') ||
        lower.contains('api_key') ||
        lower.contains('secret');
  }

  static String? _session(String rest) {
    final connected = RegExp(r'^connected (.+?) \S+ via (\w+)$').firstMatch(rest);
    if (connected != null) {
      return 'Connected to ${connected.group(1)} ${_via(connected.group(2))}.';
    }
    final restored = RegExp(r'^restored (.+?) \S+ via (\w+)$').firstMatch(rest);
    if (restored != null) {
      return 'The share with ${restored.group(1)} is back ${_via(restored.group(2))}.';
    }
    if (rest.startsWith('ended:')) {
      final why = rest.substring(6).trim();
      return why.isEmpty ? 'The share ended.' : 'The share ended. $why';
    }
    final download = RegExp(r'^download of (.+) failed: (.+)$').firstMatch(rest);
    if (download != null) {
      return 'Could not receive ${download.group(1)}. ${download.group(2)}';
    }
    final open = RegExp(r'^open \S+ failed: (.+)$').firstMatch(rest);
    if (open != null) return 'Could not open the share. ${open.group(1)}';
    final cable = RegExp(r'^cable open \S+ via \w+ -> (.+)$').firstMatch(rest);
    if (cable != null) {
      final result = cable.group(1)!;
      return result == 'ok' ? 'The cable share opened.' : 'The cable share did not open. $result';
    }
    final quiet = RegExp(r'^no answer for (\d+)s: reconnecting$').firstMatch(rest);
    if (quiet != null) return 'No answer for ${quiet.group(1)} seconds. Trying again.';
    final resumed = RegExp(r'^resumed with (.+)$').firstMatch(rest);
    if (resumed != null) return 'The share with ${resumed.group(1)} is back.';
    if (rest.startsWith('limited session')) {
      final why = RegExp(r'\((.+)\)$').firstMatch(rest)?.group(1);
      return why == null || why.isEmpty ? 'This share is limited.' : 'This share is limited. $why';
    }
    if (rest.startsWith('older SocialSave')) {
      return 'The other Social Save is an older version.';
    }
    if (rest == 'link back') return 'Looking for the other device again.';
    final trying = RegExp(r'^trying (.+?) at ').firstMatch(rest);
    if (trying != null) return 'Trying ${trying.group(1)} again.';
    if (rest == 're-joining the hotspot') return 'Joining the hotspot again.';
    if (rest == 're-opening the hotspot') return 'Turning the hotspot back on.';
    if (rest.startsWith('hotspot stopped')) {
      return 'The phone stopped the hotspot. Turning it back on.';
    }
    final send = RegExp(r'^send failed \((.+)\); retry').firstMatch(rest);
    if (send != null) return 'A send failed. Trying again. ${send.group(1)}';
    return null;
  }

  static String _via(String? link) {
    return switch (link) {
      'usb' => 'over the USB cable',
      'cable' => 'over the cable',
      'hotspot' => 'over the hotspot',
      _ => 'on this network',
    };
  }

  static String? _usb(String rest) {
    final offered = RegExp(r'^quick action offered for (.+)$').firstMatch(rest);
    if (offered != null) return 'Offered to share files with ${offered.group(1)}.';
    return null;
  }

  static String? _hotspot(String rest) {
    final reopen = RegExp(r'^reopen failed: (.+)$').firstMatch(rest);
    if (reopen != null) return 'Could not turn the hotspot back on. ${reopen.group(1)}';
    final rejoin = RegExp(r'^rejoin failed: (.+)$').firstMatch(rest);
    if (rejoin != null) return 'Could not join the hotspot again. ${rejoin.group(1)}';
    return null;
  }

  static String? _tray(String rest) {
    final init = RegExp(r'^init failed: (.+)$').firstMatch(rest);
    if (init != null) return 'The tray icon did not start. ${init.group(1)}';
    return 'The tray had a problem. $rest';
  }

  static Future<void> _read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw);
      if (list is! List) return;
      final older = <PlainLine>[];
      for (final item in list) {
        if (item is! Map) continue;
        final text = _clean('${item['text'] ?? ''}');
        final at = DateTime.tryParse('${item['at'] ?? ''}');
        if (text == null || at == null) continue;
        older.add(PlainLine(at, text));
      }
      if (older.isEmpty) return;
      _lines.insertAll(0, older);
      if (_lines.length > keep) {
        _lines.removeRange(0, _lines.length - keep);
      }
    } catch (_) {}
  }

  static Future<void> _write() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode([for (final line in _lines) line.toJson()]));
    } catch (_) {}
  }
}
