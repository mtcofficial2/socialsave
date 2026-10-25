class PlaylistEntry {
  const PlaylistEntry({
    required this.title,
    required this.url,
    this.durationSeconds,
    this.thumbnailUrl,
  });

  final String title;
  final String url;
  final int? durationSeconds;
  final String? thumbnailUrl;

  factory PlaylistEntry.fromJson(Map<String, dynamic> json) {
    final duration = json['duration'];
    final thumb = json['thumbnail'];
    final thumbText = thumb is String ? thumb.trim() : '';
    return PlaylistEntry(
      title: (json['title'] as String?)?.trim().isNotEmpty == true
          ? json['title'] as String
          : 'Video',
      url: json['url'] as String? ?? '',
      durationSeconds: duration is int
          ? duration
          : (duration is num ? duration.toInt() : null),
      thumbnailUrl: thumbText.startsWith('http') ? thumbText : null,
    );
  }
}

/// A playlist response, plus the channel name and portrait when the server sends them.
class PlaylistPage {
  const PlaylistPage({required this.items, this.name, this.avatarUrl});

  final List<PlaylistEntry> items;
  final String? name;
  final String? avatarUrl;
}
