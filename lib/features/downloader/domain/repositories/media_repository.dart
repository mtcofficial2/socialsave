import 'package:social_save/shared/models/download_ticket.dart';
import 'package:social_save/shared/models/media_info.dart';
import 'package:social_save/shared/models/platform_catalog.dart';
import 'package:social_save/shared/models/playlist_entry.dart';

abstract class MediaRepository {
  Future<MediaInfo> analyze(String url);

  Future<DownloadTicket> requestDownload({
    required String url,
    required String formatId,
  });

  Future<DownloadJobStatus> getJobStatus(String jobId);

  Future<List<PlatformCapability>> getPlatforms();

  Future<List<PlaylistEntry>> playlist(String url);

  Future<String> summarize({
    required String title,
    String? author,
    String? sourceUrl,
  });

  Future<String> createPair(List<Map<String, String>> items);
}
