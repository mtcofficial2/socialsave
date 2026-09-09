import 'package:equatable/equatable.dart';
import 'package:social_save/shared/models/download_status.dart';
import 'package:social_save/shared/models/download_task.dart';
import 'package:social_save/shared/models/social_platform.dart';

class DownloadRecord extends Equatable {
  const DownloadRecord({
    required this.id,
    required this.title,
    required this.sourceUrl,
    required this.platform,
    required this.downloadedAt,
    required this.status,
    this.thumbnailUrl,
    this.localPath,
    this.fileSize,
    this.durationSeconds,
    this.quality,
    this.format,
    this.author,
  });

  final String id;
  final String title;
  final String? thumbnailUrl;
  final String sourceUrl;
  final SocialPlatform platform;
  final String? localPath;
  final DateTime downloadedAt;
  final int? fileSize;
  final int? durationSeconds;
  final String? quality;
  final String? format;
  final String? author;
  final DownloadStatus status;

  bool get fileExistsHint => localPath != null && localPath!.isNotEmpty;

  DownloadRecord copyWith({
    String? localPath,
    DownloadStatus? status,
    bool clearPath = false,
  }) {
    return DownloadRecord(
      id: id,
      title: title,
      thumbnailUrl: thumbnailUrl,
      sourceUrl: sourceUrl,
      platform: platform,
      localPath: clearPath ? null : (localPath ?? this.localPath),
      downloadedAt: downloadedAt,
      fileSize: fileSize,
      durationSeconds: durationSeconds,
      quality: quality,
      format: format,
      author: author,
      status: status ?? this.status,
    );
  }

  factory DownloadRecord.fromTask(DownloadTask task) {
    return DownloadRecord(
      id: task.id,
      title: task.title,
      thumbnailUrl: task.thumbnailUrl,
      sourceUrl: task.sourceUrl,
      platform: task.platform,
      localPath: task.localPath,
      downloadedAt: DateTime.now(),
      fileSize: task.totalBytes ?? task.receivedBytes,
      durationSeconds: task.durationSeconds,
      quality: task.format.quality,
      format: task.format.format,
      author: task.author,
      status: task.status,
    );
  }

  factory DownloadRecord.fromJson(Map<String, dynamic> json) {
    return DownloadRecord(
      id: json['id'] as String,
      title: json['title'] as String? ?? 'Untitled video',
      thumbnailUrl: json['thumbnailUrl'] as String?,
      sourceUrl: json['sourceUrl'] as String? ?? '',
      platform: SocialPlatform.fromId(json['platform'] as String?),
      localPath: json['localPath'] as String?,
      downloadedAt: DateTime.tryParse(json['downloadedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      fileSize: json['fileSize'] as int?,
      durationSeconds: json['durationSeconds'] as int?,
      quality: json['quality'] as String?,
      format: json['format'] as String?,
      author: json['author'] as String?,
      status: DownloadStatus.fromName(json['status'] as String?),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'thumbnailUrl': thumbnailUrl,
      'sourceUrl': sourceUrl,
      'platform': platform.id,
      'localPath': localPath,
      'downloadedAt': downloadedAt.toIso8601String(),
      'fileSize': fileSize,
      'durationSeconds': durationSeconds,
      'quality': quality,
      'format': format,
      'author': author,
      'status': status.name,
    };
  }

  @override
  List<Object?> get props => [
        id,
        title,
        thumbnailUrl,
        sourceUrl,
        platform,
        localPath,
        downloadedAt,
        fileSize,
        durationSeconds,
        quality,
        format,
        author,
        status,
      ];
}
