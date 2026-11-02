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
