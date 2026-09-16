import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
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
    Map<String, String>? extraHeaders,
    void Function(DownloadProgress progress)? onProgress,
  });
}

class DioFileDownloader implements FileDownloader {
  DioFileDownloader({Dio? dio}) : _dio = dio ?? _createDio();

  final Dio _dio;

  static Dio _createDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(minutes: 30),
        sendTimeout: const Duration(seconds: 20),
        followRedirects: true,
        maxRedirects: 5,
        persistentConnection: true,
        validateStatus: (status) =>
            status != null && status >= 200 && status < 400,
        headers: {
          'Accept': '*/*',
          'Accept-Encoding': 'identity',
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/126.0.0.0 Mobile Safari/537.36',
        },
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.maxConnectionsPerHost = 16;
        client.idleTimeout = const Duration(seconds: 15);
        client.autoUncompress = false;
        client.connectionTimeout = const Duration(seconds: 12);
        return client;
      },
    );
    return dio;
  }

  static const _allowedMime = {
    'video/mp4',
    'video/webm',
    'video/quicktime',
    'video/x-m4v',
    'video/x-matroska',
    'video/mpeg',
    'audio/mp4',
    'audio/mpeg',
    'application/octet-stream',
  };

  @override
  Future<RemoteFileProbe> probe(String url, {CancelToken? cancelToken}) async {
    try {
      final response = await _dio.get<void>(
        url,
        cancelToken: cancelToken,
        options: Options(
          followRedirects: true,
          headers: {'Range': 'bytes=0-0'},
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      final headers = response.headers;
      final total = _totalFromContentRange(headers.value('content-range')) ??
          int.tryParse(headers.value('content-length') ?? '');
      return RemoteFileProbe(
        supportsResume: response.statusCode == 206,
        contentLength: total,
        contentType: headers.value('content-type'),
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) rethrow;
      return const RemoteFileProbe(supportsResume: false);
    }
  }

  int? _totalFromContentRange(String? header) {
    if (header == null) return null;
    final match = RegExp(r'bytes\s+\d+-\d+/(\d+)').firstMatch(header);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  @override
  Future<void> download({
    required String url,
    required String savePath,
    required CancelToken cancelToken,
    int startByte = 0,
    Map<String, String>? extraHeaders,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    final file = File(savePath);
    await file.parent.create(recursive: true);
    await _downloadSingle(
      url: url,
      file: file,
      cancelToken: cancelToken,
      startByte: startByte,
      extraHeaders: extraHeaders,
      onProgress: onProgress,
    );
  }

  Future<void> _downloadSingle({
    required String url,
    required File file,
    required CancelToken cancelToken,
    required int startByte,
    Map<String, String>? extraHeaders,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    final headers = <String, String>{
      if (extraHeaders != null) ...extraHeaders,
    };
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
        maxRedirects: 5,
      ),
    );

    final contentType = response.headers.value('content-type');
    _assertAllowedType(contentType);

    final status = response.statusCode ?? 200;
    final resumeAccepted = startByte > 0 && status == 206;
    final writeOffset = resumeAccepted ? startByte : 0;
    if (startByte > 0 && !resumeAccepted && await file.exists()) {
      await file.delete();
    }

    final contentLength = int.tryParse(
          response.headers.value('content-length') ?? '',
        ) ??
        _totalFromContentRange(response.headers.value('content-range'));
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
    var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await for (final chunk in response.data!.stream) {
        if (cancelToken.isCancelled) {
          throw const AppException(
            code: AppErrorCode.downloadInterrupted,
            message: ErrorMessages.downloadInterrupted,
          );
        }
        final data = Uint8List.fromList(chunk);
        await raf.writeFrom(data);
        received += data.length;
        if (received > EnvConfig.maxDownloadBytes) {
          throw const AppException(
            code: AppErrorCode.fileTooLarge,
            message: ErrorMessages.fileTooLarge,
          );
        }
        final now = DateTime.now();
        if (now.difference(lastEmit) >= const Duration(milliseconds: 120)) {
          lastEmit = now;
          onProgress?.call(DownloadProgress(received: received, total: total));
        }
      }
      onProgress?.call(DownloadProgress(received: received, total: total));
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
    if (mime.startsWith('video/') ||
        mime.startsWith('audio/') ||
        _allowedMime.contains(mime)) {
      return;
    }
    throw const AppException(
      code: AppErrorCode.unsupportedFormat,
      message: ErrorMessages.unsupportedFormat,
    );
  }
}
