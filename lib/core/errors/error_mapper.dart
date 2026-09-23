import 'dart:io';

import 'package:dio/dio.dart';
import 'package:social_save/core/config/env_config.dart';
import 'package:social_save/core/errors/error_messages.dart';
import 'package:social_save/core/errors/exceptions.dart';

class ErrorMapper {
  const ErrorMapper();

  AppException fromDio(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return AppException(
          code: AppErrorCode.timeout,
          message: _reachabilityMessage(ErrorMessages.timeout),
        );
      case DioExceptionType.connectionError:
        return AppException(
          code: AppErrorCode.networkUnavailable,
          message: _reachabilityMessage(ErrorMessages.networkUnavailable),
        );
      case DioExceptionType.cancel:
        return const AppException(
          code: AppErrorCode.downloadInterrupted,
          message: ErrorMessages.downloadInterrupted,
        );
      case DioExceptionType.badResponse:
        return fromStatus(
          error.response?.statusCode,
          error.response?.data,
        );
      case DioExceptionType.badCertificate:
        return const AppException(
          code: AppErrorCode.serverError,
          message: ErrorMessages.serverError,
        );
      case DioExceptionType.unknown:
        if (error.error is SocketException) {
          return AppException(
            code: AppErrorCode.networkUnavailable,
            message: _reachabilityMessage(ErrorMessages.networkUnavailable),
          );
        }
        return AppException(
          code: AppErrorCode.unknown,
          message: ErrorMessages.generic,
          cause: error,
        );
    }
  }

  String _reachabilityMessage(String fallback) {
    final host = Uri.tryParse(EnvConfig.apiBaseUrl)?.host.toLowerCase() ?? '';
    final local = host == 'localhost' ||
        host == '127.0.0.1' ||
        host.startsWith('192.168.') ||
        host.startsWith('10.') ||
        host.startsWith('172.');
    if (local) return ErrorMessages.computerAsleep;
    return fallback;
  }

  AppException fromStatus(int? statusCode, Object? data) {
    final parsed = _parseBody(data);
    final code = _codeFromString(parsed.code) ?? _codeFromStatus(statusCode);
    return AppException(
      code: code,
      message: parsed.message ?? ErrorMessages.forCode(code),
      statusCode: statusCode,
    );
  }

  AppException fromObject(Object error) {
    if (error is AppException) {
      return error;
    }
    if (error is DioException) {
      return fromDio(error);
    }
    if (error is SocketException) {
      return AppException(
        code: AppErrorCode.networkUnavailable,
        message: _reachabilityMessage(ErrorMessages.networkUnavailable),
      );
    }
    if (error is PathNotFoundException || error is FileSystemException) {
      return const AppException(
        code: AppErrorCode.insufficientStorage,
        message: ErrorMessages.insufficientStorage,
      );
    }
    return AppException(
      code: AppErrorCode.unknown,
      message: ErrorMessages.generic,
      cause: error,
    );
  }

  AppErrorCode _codeFromStatus(int? statusCode) {
    switch (statusCode) {
      case 400:
        return AppErrorCode.invalidUrl;
      case 401:
      case 403:
        return AppErrorCode.unauthorized;
      case 404:
        return AppErrorCode.removedVideo;
      case 413:
        return AppErrorCode.fileTooLarge;
      case 415:
        return AppErrorCode.unsupportedFormat;
      case 429:
        return AppErrorCode.rateLimited;
      case 503:
        return AppErrorCode.platformUnavailable;
      default:
        return AppErrorCode.serverError;
    }
  }

  AppErrorCode? _codeFromString(String? value) {
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
      case 'network_unavailable':
        return AppErrorCode.networkUnavailable;
      case 'unsupported_format':
        return AppErrorCode.unsupportedFormat;
      case 'file_too_large':
        return AppErrorCode.fileTooLarge;
      case 'unauthorized':
        return AppErrorCode.unauthorized;
      case 'rate_limited':
        return AppErrorCode.rateLimited;
      case 'ssrf_blocked':
        return AppErrorCode.invalidUrl;
      default:
        return null;
    }
  }

  _ParsedError _parseBody(Object? data) {
    if (data is Map<String, dynamic>) {
      final error = data['error'];
      if (error is Map<String, dynamic>) {
        return _ParsedError(
          code: error['code'] as String?,
          message: error['message'] as String?,
        );
      }
      return _ParsedError(
        code: data['code'] as String?,
        message: data['message'] as String?,
      );
    }
    return const _ParsedError();
  }
}

class _ParsedError {
  const _ParsedError({this.code, this.message});

  final String? code;
  final String? message;
}
