/// Compile-time build switches.
///
/// The Windows build passes `--dart-define=SOCIALSAVE_LOCAL_ENGINE=true`.
/// Code behind `if (!kLocalEngine)` is removed from that build by the
/// compiler, so the desktop app carries no hosted-API address at all and
/// does everything with the bundled engine on 127.0.0.1.
const bool kLocalEngine = bool.fromEnvironment('SOCIALSAVE_LOCAL_ENGINE');
