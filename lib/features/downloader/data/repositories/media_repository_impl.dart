import 'package:social_save/core/errors/error_messages.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/core/network/connectivity_service.dart';
import 'package:social_save/core/utils/url_validator.dart';
import 'package:social_save/features/downloader/data/datasources/media_api_client.dart';
import 'package:social_save/features/downloader/domain/repositories/media_repository.dart';
import 'package:social_save/shared/models/download_ticket.dart';
import 'package:social_save/shared/models/media_info.dart';
import 'package:social_save/shared/models/platform_catalog.dart';

class MediaRepositoryImpl implements MediaRepository {
  MediaRepositoryImpl({
    required MediaApiClient apiClient,
    required ConnectivityService connectivity,
    UrlValidator urlValidator = const UrlValidator(),
  })  : _apiClient = apiClient,
        _connectivity = connectivity,
        _urlValidator = urlValidator;

  final MediaApiClient _apiClient;
  final ConnectivityService _connectivity;
  final UrlValidator _urlValidator;

  @override
  Future<MediaInfo> analyze(String url) async {
    final normalized = _requireValidUrl(url);
    await _requireNetwork();
    return _apiClient.analyze(normalized);
  }

  @override
  Future<DownloadTicket> requestDownload({
    required String url,
    required String formatId,
  }) async {
    final normalized = _requireValidUrl(url);
    await _requireNetwork();
    if (formatId.trim().isEmpty) {
      throw const AppException(
        code: AppErrorCode.unsupportedFormat,
        message: ErrorMessages.unsupportedFormat,
      );
    }
    return _apiClient.requestDownload(url: normalized, formatId: formatId);
  }

  @override
  Future<DownloadJobStatus> getJobStatus(String jobId) {
    return _apiClient.getJobStatus(jobId);
  }

  @override
  Future<List<PlatformCapability>> getPlatforms() async {
    try {
      await _requireNetwork();
      return await _apiClient.getPlatforms();
    } on AppException {
      return PlatformCapability.fallbackCatalog();
    }
  }

  String _requireValidUrl(String url) {
    final result = _urlValidator.validate(url);
    if (!result.isValid || result.normalized == null) {
      throw AppException(
        code: AppErrorCode.invalidUrl,
        message: result.reason ?? ErrorMessages.invalidUrl,
      );
    }
    return result.normalized.toString();
  }

  Future<void> _requireNetwork() async {
    final access = await _connectivity.current();
    if (access == NetworkAccess.offline) {
      throw const AppException(
        code: AppErrorCode.networkUnavailable,
        message: ErrorMessages.networkUnavailable,
      );
    }
  }
}
