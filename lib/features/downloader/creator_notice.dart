/// Title of the creator notice. A blank name becomes "Creator".
String creatorNoticeTitle(String name) {
  final trimmed = name.trim();
  return trimmed.isEmpty ? 'Creator' : trimmed;
}

/// Body of the creator notice. Several new posts share one notice.
String creatorNoticeBody(int count) {
  if (count <= 1) return 'A new video is ready to download.';
  return '$count new videos are ready to download.';
}
