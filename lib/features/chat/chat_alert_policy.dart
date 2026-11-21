import 'package:flutter/widgets.dart';

/// The inbox is checked while the app is open, hidden, or asleep.
bool chatInboxCheckRuns(AppLifecycleState? life) {
  switch (life) {
    case AppLifecycleState.resumed:
    case AppLifecycleState.inactive:
    case AppLifecycleState.hidden:
    case AppLifecycleState.paused:
    case AppLifecycleState.detached:
    case null:
      return true;
  }
}

/// True when someone is in front of a visible Social Save window.
bool chatUserIsHere({
  required AppLifecycleState? life,
  required bool screenOn,
}) {
  final resumed = life == null || life == AppLifecycleState.resumed;
  return resumed && screenOn;
}

/// Whether a timed check should hit the server now. While the live
/// connection is up, new messages and calls arrive over it, so the timed
/// check only runs as a slow safety net instead of every few seconds.
bool chatPollDue({
  required bool live,
  required DateTime? last,
  required DateTime now,
  Duration liveGap = const Duration(seconds: 30),
}) {
  if (!live || last == null) return true;
  return now.difference(last) >= liveGap;
}
