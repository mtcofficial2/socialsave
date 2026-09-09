import 'package:social_save/shared/models/download_ticket.dart';
import 'package:social_save/shared/models/media_info.dart';
import 'package:social_save/shared/models/platform_catalog.dart';

abstract class MediaRepository {
  Future<MediaInfo> analyze(String url);

  Future<DownloadTicket> requestDownload({
    required String url,
    required String formatId,
  });

  Future<DownloadJobStatus> getJobStatus(String jobId);

  Future<List<PlatformCapability>> getPlatforms();
}
