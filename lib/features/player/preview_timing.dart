import 'dart:io';

import 'package:flutter/foundation.dart';

/// Preview start-up timing (1.0.45). Each step is logged with the time since
/// the Preview tap, to the debug console and to
/// `<temp>/socialsave_preview.log`, so time-to-first-frame can be measured.
class PreviewTiming {
  PreviewTiming._();

  /// Test hook (`--preview-legacy`): the 1.0.44 path, for before/after numbers.
  static bool legacy = false;

  static final Stopwatch _watch = Stopwatch();
  static String _url = '';
  static bool get running => _watch.isRunning;

  static void start(String url) {
    _url = url;
    _watch
      ..reset()
      ..start();
    log('preview start ${legacy ? 'legacy' : 'fast'} $url');
  }

  static void mark(String step) {
    if (!_watch.isRunning) return;
    log('preview $step ms=${_watch.elapsedMilliseconds} ${legacy ? 'legacy' : 'fast'} $_url');
  }

  static void stop(String step) {
    mark(step);
    _watch.stop();
  }

  static void log(String line) {
    // ignore: avoid_print
    print('debug $line');
    if (kIsWeb) return;
    try {
      File('${Directory.systemTemp.path}${Platform.pathSeparator}socialsave_preview.log')
          .writeAsStringSync('${DateTime.now().toIso8601String()} $line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }
}
