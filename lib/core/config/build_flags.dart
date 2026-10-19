import 'package:flutter/foundation.dart';

/// Compile-time build switches.
///
/// The Windows build passes `--dart-define=SOCIALSAVE_LOCAL_ENGINE=true`.
///
/// 1.0.44: Windows release builds now always use the bundled engine, even if
/// the define was forgotten. 1.0.41-1.0.43 were built without it, so the
/// desktop app silently talked to the hosted server; YouTube answers that
/// server's data-centre IP with "Sign in to confirm you're not a bot", which
/// came back as "private, age-restricted, or members-only". The desktop app
/// never needs the hosted API.
final bool kLocalEngine = const bool.fromEnvironment('SOCIALSAVE_LOCAL_ENGINE') ||
    (!kIsWeb && kReleaseMode && defaultTargetPlatform == TargetPlatform.windows);
