import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/shared/models/social_platform.dart';

class PlayerSession {
  const PlayerSession({
    required this.title,
    required this.platform,
    this.filePath,
    this.networkUrl,
    this.thumbnailUrl,
    this.author,
    this.referer,
    this.httpHeaders,
    this.isPreview = false,
    this.isVault = false,
  });

  final String title;
  final SocialPlatform platform;
  final String? filePath;
  final String? networkUrl;
  final String? thumbnailUrl;
  final String? author;
  final String? referer;
  final Map<String, String>? httpHeaders;
  final bool isPreview;
  final bool isVault;

  factory PlayerSession.fromRecord(DownloadRecord record) {
    return PlayerSession(
      title: record.title,
      platform: record.platform,
      filePath: record.localPath,
      thumbnailUrl: record.thumbnailUrl,
      author: record.author,
      referer: record.sourceUrl,
    );
  }
}
