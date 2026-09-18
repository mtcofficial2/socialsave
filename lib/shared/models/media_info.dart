import 'package:equatable/equatable.dart';
import 'package:social_save/shared/models/media_format.dart';
import 'package:social_save/shared/models/social_platform.dart';

class MediaInfo extends Equatable {
  const MediaInfo({
    required this.sourceUrl,
    required this.platform,
    required this.title,
    required this.formats,
    this.thumbnailUrl,
    this.author,
    this.durationSeconds,
    this.canDownload = false,
    this.downloadRestrictedReason,
  });

  final String sourceUrl;
  final SocialPlatform platform;
  final String title;
  final String? thumbnailUrl;
  final String? author;
  final int? durationSeconds;
  final List<MediaFormat> formats;
  final bool canDownload;
  final String? downloadRestrictedReason;

  MediaFormat? get defaultFormat {
    if (formats.isEmpty) {
      return null;
    }
    MediaFormat? byQuality(String quality) {
      for (final format in formats) {
        if (format.quality.toLowerCase() == quality) {
          return format;
        }
      }
      return null;
    }

    return byQuality('auto') ??
        byQuality('1080p') ??
        byQuality('720p') ??
        byQuality('480p') ??
        byQuality('original') ??
        formats.first;
  }

  List<MediaFormat> get videoFormats =>
      formats.where((format) => format.hasVideo).toList();

  factory MediaInfo.fromJson(Map<String, dynamic> json, {String? fallbackUrl}) {
    final formatsJson = json['formats'];
    final formats = <MediaFormat>[];
    if (formatsJson is List) {
      for (final item in formatsJson) {
        if (item is Map<String, dynamic>) {
          formats.add(MediaFormat.fromJson(item));
        } else if (item is Map) {
          formats.add(
            MediaFormat.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }

    return MediaInfo(
      sourceUrl: json['url'] as String? ?? fallbackUrl ?? '',
      platform: SocialPlatform.fromId(json['platform'] as String?),
      title: (json['title'] as String?)?.trim().isNotEmpty == true
          ? json['title'] as String
          : 'Untitled video',
      thumbnailUrl: json['thumbnail'] as String?,
      author: json['author'] as String?,
      durationSeconds: MediaFormat.parseInt(json['duration']),
      formats: formats,
      canDownload: json['can_download'] as bool? ?? formats.isNotEmpty,
      downloadRestrictedReason: json['download_restricted_reason'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'url': sourceUrl,
      'platform': platform.id,
      'title': title,
      'thumbnail': thumbnailUrl,
      'author': author,
      'duration': durationSeconds,
      'formats': formats.map((format) => format.toJson()).toList(),
      'can_download': canDownload,
      'download_restricted_reason': downloadRestrictedReason,
    };
  }

  @override
  List<Object?> get props => [
        sourceUrl,
        platform,
        title,
        thumbnailUrl,
        author,
        durationSeconds,
        formats,
        canDownload,
        downloadRestrictedReason,
      ];
}
