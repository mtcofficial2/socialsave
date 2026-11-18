import 'package:flutter/services.dart';
import 'package:social_save/core/diagnostics/plain_log.dart';
import 'package:social_save/core/platform/plat.dart';

/// Social Save's own actions, plus the other apps this phone used.
class PhoneActivity {
  PhoneActivity._();

  static const _channel = MethodChannel('socialsave/media');
  static var _askedUsage = false;
  static String _screen = '';

  /// Records a screen change once. Tab changes and pushed pages both call this.
  static void sawScreen(String path) {
    final sentence = PlainLog.screenSentence(path);
    if (sentence == null || sentence == _screen) return;
    _screen = sentence;
    PlainLog.note(sentence);
  }

  /// Lines for the computer: what Social Save did, then what the phone used.
  static Future<List<Map<String, String>>> forCable() async {
    await PlainLog.load();
    final lines = <Map<String, String>>[
      for (final line in PlainLog.lines) line.toJson(),
    ];
    lines.addAll(await _usage());
    lines.sort((a, b) => (a['at'] ?? '').compareTo(b['at'] ?? ''));
    if (lines.length > 250) return lines.sublist(lines.length - 250);
    return lines;
  }

  static Future<List<Map<String, String>>> _usage() async {
    if (!Plat.isAndroid) return const [];
    try {
      final raw = await _channel.invokeMethod<dynamic>('phoneUsage');
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
            'text': 'Allow Social Save under Usage access on this phone to see the other apps it uses.',
          },
        ];
      }
      final rows = raw['lines'];
      if (rows is! List) return const [];
      final lines = <Map<String, String>>[];
      for (final row in rows) {
        if (row is! Map) continue;
        final text = '${row['text'] ?? ''}'.trim();
        if (text.isEmpty) continue;
        lines.add({'at': '${row['at'] ?? ''}', 'text': text});
      }
      return lines;
    } catch (_) {
      return const [];
    }
  }
}
