import 'package:equatable/equatable.dart';

class MediaFormat extends Equatable {
  const MediaFormat({
    required this.id,
    required this.quality,
    required this.format,
    this.filesize,
    this.width,
    this.height,
    this.hasAudio = true,
    this.hasVideo = true,
  });

  final String id;
  final String quality;
  final String format;
  final int? filesize;
  final int? width;
  final int? height;
  final bool hasAudio;
  final bool hasVideo;

  String get label {
    if (quality.toLowerCase() == 'auto') {
      return 'Auto';
    }
    if (quality.toLowerCase() == 'original') {
      return 'Original · ${format.toUpperCase()}';
    }
    return '$quality · ${format.toUpperCase()}';
  }

  factory MediaFormat.fromJson(Map<String, dynamic> json) {
    return MediaFormat(
      id: json['id'] as String? ?? json['format_id'] as String? ?? 'original',
      quality: json['quality'] as String? ?? 'original',
      format: json['format'] as String? ?? 'mp4',
      filesize: parseInt(json['filesize'] ?? json['file_size']),
      width: parseInt(json['width']),
      height: parseInt(json['height']),
      hasAudio: json['has_audio'] as bool? ?? true,
      hasVideo: json['has_video'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'quality': quality,
      'format': format,
      'filesize': filesize,
      'width': width,
      'height': height,
      'has_audio': hasAudio,
      'has_video': hasVideo,
    };
  }

  static int? parseInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  @override
  List<Object?> get props =>
      [id, quality, format, filesize, width, height, hasAudio, hasVideo];
}
