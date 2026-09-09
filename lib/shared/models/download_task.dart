import 'package:equatable/equatable.dart';
import 'package:social_save/shared/models/download_status.dart';
import 'package:social_save/shared/models/media_format.dart';
import 'package:social_save/shared/models/media_info.dart';
import 'package:social_save/shared/models/social_platform.dart';

class DownloadTask extends Equatable {
  const DownloadTask({
    required this.id,
    required this.sourceUrl,
    required this.downloadUrl,
    required this.title,
    required this.platform,
    required this.format,
    required this.status,
    this.thumbnailUrl,
    this.author,
    this.durationSeconds,
    this.receivedBytes = 0,
    this.totalBytes,
    this.bytesPerSecond = 0,
    this.localPath,
    this.errorMessage,
    this.supportsResume = false,
    this.createdAt,
    this.jobId,
  });

  final String id;
  final String sourceUrl;
  final String downloadUrl;
  final String title;
  final String? thumbnailUrl;
  final String? author;
  final SocialPlatform platform;
  final MediaFormat format;
  final DownloadStatus status;
  final int receivedBytes;
  final int? totalBytes;
  final double bytesPerSecond;
  final String? localPath;
  final String? errorMessage;
  final bool supportsResume;
  final int? durationSeconds;
  final DateTime? createdAt;
  final String? jobId;

  double get progress {
    final total = totalBytes;
    if (total == null || total <= 0) {
      return 0;
    }
    return (receivedBytes / total).clamp(0, 1);
  }

  Duration? get eta {
    if (bytesPerSecond <= 0 || totalBytes == null) {
      return null;
    }
    final remaining = totalBytes! - receivedBytes;
    if (remaining <= 0) {
      return Duration.zero;
    }
    return Duration(seconds: (remaining / bytesPerSecond).round());
  }

  DownloadTask copyWith({
    DownloadStatus? status,
    int? receivedBytes,
    int? totalBytes,
    double? bytesPerSecond,
    String? localPath,
    String? errorMessage,
    bool? supportsResume,
    String? downloadUrl,
    String? jobId,
    bool clearError = false,
  }) {
    return DownloadTask(
      id: id,
      sourceUrl: sourceUrl,
      downloadUrl: downloadUrl ?? this.downloadUrl,
      title: title,
      thumbnailUrl: thumbnailUrl,
      author: author,
      platform: platform,
      format: format,
      status: status ?? this.status,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
      localPath: localPath ?? this.localPath,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      supportsResume: supportsResume ?? this.supportsResume,
      durationSeconds: durationSeconds,
      createdAt: createdAt,
      jobId: jobId ?? this.jobId,
    );
  }

  factory DownloadTask.fromMedia({
    required String id,
    required MediaInfo media,
    required MediaFormat format,
    required String downloadUrl,
    int? totalBytes,
    String? jobId,
  }) {
    return DownloadTask(
      id: id,
      sourceUrl: media.sourceUrl,
      downloadUrl: downloadUrl,
      jobId: jobId,
      title: media.title,
      thumbnailUrl: media.thumbnailUrl,
      author: media.author,
      platform: media.platform,
      format: format,
      status: DownloadStatus.queued,
      totalBytes: totalBytes ?? format.filesize,
      durationSeconds: media.durationSeconds,
      createdAt: DateTime.now(),
    );
  }

  @override
  List<Object?> get props => [
        id,
        sourceUrl,
        downloadUrl,
        title,
        thumbnailUrl,
        author,
        platform,
        format,
        status,
        receivedBytes,
        totalBytes,
        bytesPerSecond,
        localPath,
        errorMessage,
        supportsResume,
        durationSeconds,
        createdAt,
        jobId,
      ];
}
