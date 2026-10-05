class PlaylistEntry {
  const PlaylistEntry({
    required this.title,
    required this.url,
    this.durationSeconds,
  });

  final String title;
  final String url;
  final int? durationSeconds;

  factory PlaylistEntry.fromJson(Map<String, dynamic> json) {
    final duration = json['duration'];
    return PlaylistEntry(
      title: (json['title'] as String?)?.trim().isNotEmpty == true
          ? json['title'] as String
          : 'Video',
      url: json['url'] as String? ?? '',
      durationSeconds: duration is int ? duration : (duration is num ? duration.toInt() : null),
    );
  }
}
