import 'package:social_save/core/constants/api_endpoints.dart';
import 'package:social_save/core/errors/error_messages.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/core/network/dio_client.dart';
import 'package:social_save/shared/models/download_ticket.dart';
import 'package:social_save/shared/models/media_info.dart';
import 'package:social_save/shared/models/platform_catalog.dart';

class MediaApiClient {
  MediaApiClient(this._client);

  final DioClient _client;

  Future<MediaInfo> analyze(String url) async {
    final response = await _client.post<Map<String, dynamic>>(
      ApiEndpoints.analyze,
      data: {'url': url},
    );
    final data = _requireMap(response.data);
    _ensureSuccess(data);
    return MediaInfo.fromJson(data, fallbackUrl: url);
  }

  Future<DownloadTicket> requestDownload({
    required String url,
    required String formatId,
  }) async {
    final response = await _client.post<Map<String, dynamic>>(
      ApiEndpoints.download,
      data: {
        'url': url,
        'format_id': formatId,
      },
    );
    final data = _requireMap(response.data);
    _ensureSuccess(data);
    return DownloadTicket.fromJson(data);
  }

  Future<DownloadJobStatus> getJobStatus(String jobId) async {
    final response = await _client.get<Map<String, dynamic>>(
      ApiEndpoints.downloadStatus(jobId),
    );
    final data = _requireMap(response.data);
    return DownloadJobStatus.fromJson(data);
  }

  Future<List<PlatformCapability>> getPlatforms() async {
    final response = await _client.get<Map<String, dynamic>>(
      ApiEndpoints.platforms,
    );
    final data = _requireMap(response.data);
    final items = data['platforms'];
    if (items is! List) {
      return PlatformCapability.fallbackCatalog();
    }
    return items
        .whereType<Map<dynamic, dynamic>>()
        .map(
          (item) => PlatformCapability.fromJson(
            Map<String, dynamic>.from(item),
          ),
        )
        .toList();
  }

  Map<String, dynamic> _requireMap(Map<String, dynamic>? data) {
    if (data == null) {
      throw const AppException(
        code: AppErrorCode.serverError,
        message: ErrorMessages.serverError,
      );
    }
    return data;
  }

  void _ensureSuccess(Map<String, dynamic> data) {
    final success = data['success'];
    if (success is bool && !success) {
      final error = data['error'];
      if (error is Map<String, dynamic>) {
        throw AppException(
          code: _codeFrom(error['code'] as String?),
          message: error['message'] as String? ?? ErrorMessages.generic,
        );
      }
      throw const AppException(
        code: AppErrorCode.serverError,
        message: ErrorMessages.serverError,
      );
    }
  }

  AppErrorCode _codeFrom(String? value) {
    switch (value) {
      case 'invalid_url':
        return AppErrorCode.invalidUrl;
      case 'unsupported_platform':
        return AppErrorCode.unsupportedPlatform;
      case 'private_video':
        return AppErrorCode.privateVideo;
      case 'removed_video':
        return AppErrorCode.removedVideo;
      case 'platform_unavailable':
        return AppErrorCode.platformUnavailable;
      case 'platform_disabled':
        return AppErrorCode.platformDisabled;
      case 'download_not_permitted':
        return AppErrorCode.downloadNotPermitted;
      case 'unsupported_format':
        return AppErrorCode.unsupportedFormat;
      case 'file_too_large':
        return AppErrorCode.fileTooLarge;
      case 'unauthorized':
        return AppErrorCode.unauthorized;
      case 'rate_limited':
        return AppErrorCode.rateLimited;
      default:
        return AppErrorCode.serverError;
    }
  }
}
