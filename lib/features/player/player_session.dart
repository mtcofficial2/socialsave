import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/shared/models/social_platform.dart';

class PlayerQueueItem {
  const PlayerQueueItem({
    required this.title,
    this.filePath,
    this.deviceId,
    this.devicePath,
    this.deviceUri,
    this.networkUrl,
    this.httpHeaders,
    this.referer,
    this.platform = SocialPlatform.direct,
    this.isVault = false,
  });

  final String title;
  final String? filePath;
  final String? deviceId;
  final String? devicePath;
  final String? deviceUri;
  final String? networkUrl;
  final Map<String, String>? httpHeaders;
  final String? referer;
  final SocialPlatform platform;
  final bool isVault;

  PlayerQueueItem copyWith({String? filePath}) {
    return PlayerQueueItem(
      title: title,
      filePath: filePath ?? this.filePath,
      deviceId: deviceId,
      devicePath: devicePath,
      deviceUri: deviceUri,
      networkUrl: networkUrl,
      httpHeaders: httpHeaders,
      referer: referer,
      platform: platform,
      isVault: isVault,
    );
  }

  PlayerSession toSession() {
    return PlayerSession(
      title: title,
      platform: platform,
      filePath: filePath,
      networkUrl: networkUrl,
      httpHeaders: httpHeaders,
      referer: referer,
      isVault: isVault,
    );
  }
}

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
    this.queue = const [],
    this.queueIndex = 0,
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
  final List<PlayerQueueItem> queue;
  final int queueIndex;

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
