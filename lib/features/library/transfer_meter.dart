/// Live transfer speed and time left, smoothed so the numbers do not jump.
class TransferMeter {
  TransferMeter();

  final Stopwatch _clock = Stopwatch()..start();
  int _lastBytes = 0;
  int _lastMs = 0;
  int _uiMs = -1000;
  double _speed = 0; // bytes per second, smoothed
  int bytes = 0;
  int total = 0;

  /// Feed the running byte count. Returns true about 4 times a second,
  /// when the UI should refresh.
  bool update(int done, int totalBytes) {
    bytes = done;
    total = totalBytes;
    final now = _clock.elapsedMilliseconds;
    final dt = now - _lastMs;
    if (dt >= 250) {
      final inst = (done - _lastBytes) * 1000 / dt;
      // EMA with ~1.5 s time constant.
      final alpha = 1 - _exp(-dt / 1500);
      _speed = _speed == 0 ? inst : _speed + alpha * (inst - _speed);
      _lastBytes = done;
      _lastMs = now;
    }
    if (now - _uiMs >= 250 || (total > 0 && done >= total)) {
      _uiMs = now;
      return true;
    }
    return false;
  }

  double get speed => _speed;
  Duration get elapsed => _clock.elapsed;

  Duration? get timeLeft {
    if (total <= 0 || _speed <= 1) return null;
    final left = (total - bytes) / _speed;
    return Duration(milliseconds: (left * 1000).round());
  }

  /// e.g. "12.3 MB / 40.0 MB · 3.2 MB/s · 9 s left"
  String get label {
    final parts = <String>[
      total > 0 ? '${formatBytes(bytes)} / ${formatBytes(total)}' : formatBytes(bytes),
      if (_speed > 0) '${formatBytes(_speed.round())}/s',
      if (timeLeft != null) '${formatEta(timeLeft!)} left',
    ];
    return parts.join(' · ');
  }

  /// e.g. "Done in 6 s at 5.4 MB/s"
  String get doneLabel {
    final secs = _clock.elapsedMilliseconds / 1000;
    final avg = secs > 0 ? bytes / secs : 0;
    return 'Done in ${formatEta(_clock.elapsed)} at ${formatBytes(avg.round())}/s';
  }

  static double _exp(double x) {
    // Small helper to avoid importing dart:math in callers.
    var sum = 1.0, term = 1.0;
    for (var i = 1; i < 20; i++) {
      term *= x / i;
      sum += term;
    }
    return sum;
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String formatEta(Duration d) {
  final s = d.inSeconds;
  if (s < 1) return '${d.inMilliseconds} ms'.replaceFirst(RegExp(r'^0 ms$'), '<1 s');
  if (s < 60) return '$s s';
  final m = s ~/ 60;
  final r = (s % 60).toString().padLeft(2, '0');
  if (m < 60) return '$m min $r s';
  return '${m ~/ 60} h ${(m % 60).toString().padLeft(2, '0')} min';
}
