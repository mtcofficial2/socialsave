import 'package:social_save/core/engine/phone_engine.dart';
import 'package:social_save/core/errors/error_messages.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/core/utils/url_validator.dart';
import 'package:social_save/features/downloader/domain/repositories/media_repository.dart';
import 'package:social_save/shared/models/download_ticket.dart';
import 'package:social_save/shared/models/media_info.dart';
import 'package:social_save/shared/models/platform_catalog.dart';
import 'package:social_save/shared/models/playlist_entry.dart';

/// Android: analyze and save go to the on-phone engine while "Download on
/// this phone (no server)" is on, and to the hosted API otherwise. Job
/// status follows the job id, so a save keeps its engine if the switch
/// changes mid-way. There is no silent fallback: an engine error is shown
/// with "Try with server", which calls [hosted] explicitly.
class RoutingMediaRepository implements MediaRepository {
  RoutingMediaRepository({required this.hosted, required UrlValidator urlValidator})
      : _urlValidator = urlValidator;

  final MediaRepository hosted;
  final UrlValidator _urlValidator;

  String _valid(String url) {
    final result = _urlValidator.validate(url);
    if (!result.isValid || result.normalized == null) {
      throw AppException(
        code: AppErrorCode.invalidUrl,
        message: result.reason ?? ErrorMessages.invalidUrl,
      );
    }
    return result.normalized.toString();
  }

  bool _serverOnce(String url) {
    final set = PhoneEngine.serverFor;
    if (set.isEmpty) return false;
    if (set.contains(url.trim())) return true;
    final result = _urlValidator.validate(url);
    return result.normalized != null && set.contains(result.normalized.toString());
  }

  @override
  Future<MediaInfo> analyze(String url) async {
    if (await PhoneEngine.isEnabled() && !_serverOnce(url)) {
      return PhoneEngine.analyze(_valid(url));
    }
    return hosted.analyze(url);
  }

  @override
  Future<DownloadTicket> requestDownload({required String url, required String formatId}) async {
    if (await PhoneEngine.isEnabled()) {
      if (!_serverOnce(url)) return PhoneEngine.start(url: _valid(url), formatId: formatId);
      final ticket = await hosted.requestDownload(url: url, formatId: formatId);
      PhoneEngine.serverFor
        ..remove(url.trim())
        ..remove(_urlValidator.validate(url).normalized?.toString());
      return ticket;
    }
    return hosted.requestDownload(url: url, formatId: formatId);
  }

  @override
  Future<DownloadJobStatus> getJobStatus(String jobId) {
    if (jobId.startsWith(PhoneEngine.jobPrefix)) return PhoneEngine.job(jobId);
    return hosted.getJobStatus(jobId);
  }

  @override
  Future<List<PlatformCapability>> getPlatforms() => hosted.getPlatforms();

  @override
  Future<List<PlaylistEntry>> playlist(String url) => hosted.playlist(url);

  @override
  Future<String> summarize({required String title, String? author, String? sourceUrl}) =>
      hosted.summarize(title: title, author: author, sourceUrl: sourceUrl);

  @override
  Future<String> createPair(List<Map<String, String>> items) => hosted.createPair(items);
}
