import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Records a failure the app deliberately keeps quiet about (best-effort
/// background work such as saving a preference, a platform probe, or a
/// keep-alive ping). Nothing is shown to the user and nothing is written in
/// release builds; in debug and profile builds it shows up in the console
/// and DevTools under `socialsave.<where>`.
void logQuiet(String where, Object error, [StackTrace? stack]) {
  if (kReleaseMode) return;
  developer.log(
    '$error',
    name: 'socialsave.$where',
    error: error,
    stackTrace: stack,
  );
}
