import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:social_save/core/config/env_config.dart';
import 'package:social_save/core/errors/error_messages.dart';
import 'package:social_save/core/errors/exceptions.dart';

class DownloadProgress {
  const DownloadProgress({
    required this.received,
    required this.total,
  });

  final int received;
  final int? total;
}

class RemoteFileProbe {
  const RemoteFileProbe({
    required this.supportsResume,
    this.contentLength,
    this.contentType,
  });

  final bool supportsResume;
  final int? contentLength;
  final String? contentType;
}

abstract class FileDownloader {
  Future<RemoteFileProbe> probe(String url, {CancelToken? cancelToken});

  Future<void> download({
    required String url,
    required String savePath,
    required CancelToken cancelToken,
    int startByte = 0,
    void Function(DownloadProgress progress)? onProgress,
  });
}

class DioFileDownloader implements FileDownloader {
  DioFileDownloader({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 20),
                receiveTimeout: Duration(
                  seconds: EnvConfig.downloadTimeoutSeconds,
                ),
                followRedirects: true,
                maxRedirects: 3,
                validateStatus: (status) =>
                    status != null && status >= 200 && status < 400,
              ),
            );

  final Dio _dio;

  static const _allowedMime = {
    'video/mp4',
    'video/webm',
    'video/quicktime',
    'video/x-m4v',
    'video/x-matroska',
    'video/mpeg',
    'application/octet-stream',
  };

  @override
  Future<RemoteFileProbe> probe(String url, {CancelToken? cancelToken}) async {
    try {
      final response = await _dio.head<void>(
        url,
        cancelToken: cancelToken,
        options: Options(
          followRedirects: true,
          maxRedirects: 3,
        ),
      );
      final lengthHeader = response.headers.value('content-length');
      final acceptRanges = response.headers.value('accept-ranges');
      final contentType = response.headers.value('content-type');
      _assertAllowedType(contentType);
      final length = int.tryParse(lengthHeader ?? '');
      if (length != null && length > EnvConfig.maxDownloadBytes) {
        throw const AppException(
          code: AppErrorCode.fileTooLarge,
          message: ErrorMessages.fileTooLarge,
        );
      }
      return RemoteFileProbe(
        supportsResume: (acceptRanges ?? '').toLowerCase().contains('bytes'),
        contentLength: length,
        contentType: contentType,
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) {
        rethrow;
      }
      // Some CDNs reject HEAD. Continue with a GET-based download.
      return const RemoteFileProbe(supportsResume: false);
    }
  }

  @override
  Future<void> download({
    required String url,
    required String savePath,
    required CancelToken cancelToken,
    int startByte = 0,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    final file = File(savePath);
    await file.parent.create(recursive: true);

    final headers = <String, String>{};
    if (startByte > 0) {
      headers['Range'] = 'bytes=$startByte-';
    }

    final response = await _dio.get<ResponseBody>(
      url,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        headers: headers,
        followRedirects: true,
        maxRedirects: 3,
      ),
    );

    final contentType = response.headers.value('content-type');
    _assertAllowedType(contentType);

    final status = response.statusCode ?? 200;
    final resumeAccepted = startByte > 0 && status == 206;
    final writeOffset = resumeAccepted ? startByte : 0;
    if (startByte > 0 && !resumeAccepted) {
      if (await file.exists()) {
        await file.delete();
      }
    }

    final contentLength = int.tryParse(
      response.headers.value('content-length') ?? '',
    );
    final total = contentLength == null
        ? null
        : (resumeAccepted ? writeOffset + contentLength : contentLength);

    if (total != null && total > EnvConfig.maxDownloadBytes) {
      throw const AppException(
        code: AppErrorCode.fileTooLarge,
        message: ErrorMessages.fileTooLarge,
      );
    }

    final raf = await file.open(
      mode: writeOffset > 0 ? FileMode.append : FileMode.write,
    );
    var received = writeOffset;
    try {
      await for (final chunk in response.data!.stream) {
        if (cancelToken.isCancelled) {
          throw const AppException(
            code: AppErrorCode.downloadInterrupted,
            message: ErrorMessages.downloadInterrupted,
          );
        }
        await raf.writeFrom(Uint8List.fromList(chunk));
        received += chunk.length;
        if (received > EnvConfig.maxDownloadBytes) {
          throw const AppException(
            code: AppErrorCode.fileTooLarge,
            message: ErrorMessages.fileTooLarge,
          );
        }
        onProgress?.call(DownloadProgress(received: received, total: total));
      }
    } on PathAccessException {
      throw const AppException(
        code: AppErrorCode.permissionDenied,
        message: ErrorMessages.permissionDenied,
      );
    } on FileSystemException {
      throw const AppException(
        code: AppErrorCode.insufficientStorage,
        message: ErrorMessages.insufficientStorage,
      );
    } finally {
      await raf.close();
    }
  }

  void _assertAllowedType(String? contentType) {
    if (contentType == null || contentType.isEmpty) {
      return;
    }
    final mime = contentType.split(';').first.trim().toLowerCase();
    if (mime.startsWith('text/html') || mime.startsWith('application/json')) {
      throw const AppException(
        code: AppErrorCode.unsupportedFormat,
        message: ErrorMessages.unsupportedFormat,
      );
    }
    if (mime.startsWith('video/') || _allowedMime.contains(mime)) {
      return;
    }
    throw const AppException(
      code: AppErrorCode.unsupportedFormat,
      message: ErrorMessages.unsupportedFormat,
    );
  }
}
