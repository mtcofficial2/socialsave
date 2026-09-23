/// Where a saved video should reopen.
///
/// Dart's [String.hashCode] is not stable across app launches, so the key is
/// the file path or the device library id itself.
String? resumeStorageKey({
  required bool isPreview,
  String? deviceId,
  String? filePath,
}) {
  if (isPreview) return null;
  final path = filePath?.trim();
  if (path != null && path.isNotEmpty) {
    return 'player.pos.v2.file.$path';
  }
  final id = deviceId?.trim();
  if (id != null && id.isNotEmpty) {
    return 'player.pos.v2.device.$id';
  }
  return null;
}

/// Position worth keeping, or null when the next open should start at 0.
int? positionToStore({
  required int positionMs,
  required int durationMs,
  required bool completed,
}) {
  if (completed) return null;
  if (positionMs < 1000) return null;
  if (durationMs > 0 && positionMs >= durationMs - 3000) return null;
  return positionMs;
}

/// Whether [savedMs] is a real stopping point for a video of [durationMs].
/// Pass `0` when the duration is not known yet.
bool shouldResume(int? savedMs, int durationMs) {
  if (savedMs == null || savedMs < 1000) return false;
  if (durationMs <= 0) return true;
  if (savedMs >= durationMs - 3000) return false;
  return savedMs < durationMs;
}

String formatResumeClock(Duration position) {
  final hours = position.inHours;
  final minutes = position.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = position.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) return '$hours:$minutes:$seconds';
  return '${position.inMinutes}:$seconds';
}
