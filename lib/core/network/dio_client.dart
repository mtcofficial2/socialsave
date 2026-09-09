import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:social_save/core/config/env_config.dart';
import 'package:social_save/core/errors/error_mapper.dart';
import 'package:social_save/core/errors/exceptions.dart';

class DioClient {
  DioClient({
    Dio? dio,
    ErrorMapper errorMapper = const ErrorMapper(),
    String? baseUrl,
  })  : _errorMapper = errorMapper,
        _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl ?? EnvConfig.apiBaseUrl,
                connectTimeout: Duration(
                  seconds: EnvConfig.analyzeTimeoutSeconds,
                ),
                receiveTimeout: Duration(
                  seconds: EnvConfig.analyzeTimeoutSeconds,
                ),
                sendTimeout: Duration(seconds: EnvConfig.analyzeTimeoutSeconds),
                headers: {
                  'Accept': 'application/json',
                  'Content-Type': 'application/json',
                  if (EnvConfig.hasApiKey)
                    'Authorization': 'Bearer ${EnvConfig.apiKey}',
                },
              ),
            ) {
    _dio.interceptors.addAll([
      _AuthInterceptor(),
      if (kDebugMode && EnvConfig.enableLogging)
        LogInterceptor(
          requestBody: true,
          responseBody: true,
          logPrint: (object) => debugPrint(object.toString()),
        ),
    ]);
  }

  final Dio _dio;
  final ErrorMapper _errorMapper;

  Dio get raw => _dio;

  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? query,
    Options? options,
    CancelToken? cancelToken,
  }) {
    return _guard(
      () => _dio.get<T>(
        path,
        queryParameters: query,
        options: options,
        cancelToken: cancelToken,
      ),
    );
  }

  Future<Response<T>> post<T>(
    String path, {
    Object? data,
    Options? options,
    CancelToken? cancelToken,
  }) {
    return _guard(
      () => _dio.post<T>(
        path,
        data: data,
        options: options,
        cancelToken: cancelToken,
      ),
    );
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on DioException catch (error) {
      throw _errorMapper.fromDio(error);
    } catch (error) {
      throw _errorMapper.fromObject(error);
    }
  }
}

class _AuthInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (EnvConfig.hasApiKey &&
        (options.headers['Authorization'] == null ||
            options.headers['Authorization'].toString().isEmpty)) {
      options.headers['Authorization'] = 'Bearer ${EnvConfig.apiKey}';
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.response?.statusCode == 401) {
      handler.next(
        DioException(
          requestOptions: err.requestOptions,
          response: err.response,
          type: DioExceptionType.badResponse,
          error: const AppException(
            code: AppErrorCode.unauthorized,
            message:
                'The app is not authorized to talk to the backend. Check API configuration.',
            statusCode: 401,
          ),
        ),
      );
      return;
    }
    handler.next(err);
  }
}
