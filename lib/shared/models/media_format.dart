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

  /// Quality as people read it. 1.0.37: portrait videos (TikTok, Shorts)
  /// were labelled by their long side, so a 720 × 1280 TikTok showed as
  /// "1440p". The short side is the "p" number; the id stays the same.
  String get displayQuality {
    final q = quality.toLowerCase();
    if (q == 'auto') return 'Auto';
    if (q == 'audio' || (!hasVideo && hasAudio)) return 'Audio';
    final w = width, h = height;
    if (RegExp(r'^\d+p$').hasMatch(q) && w != null && h != null && w > 0 && w < h) {
      return '${w}p';
    }
    return quality;
  }

  String get label {
    if (!hasVideo && hasAudio || quality.toLowerCase() == 'audio') {
      return 'Audio only';
    }
    if (quality.toLowerCase() == 'auto') {
      return 'Auto';
    }
    if (quality.toLowerCase() == 'original') {
      return 'Original · ${format.toUpperCase()}';
    }
    return '$displayQuality · ${format.toUpperCase()}';
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
