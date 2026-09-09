import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/core/network/dio_client.dart';
import 'package:social_save/features/downloader/data/datasources/media_api_client.dart';

Dio _dioWith(int status, Map<String, dynamic> body) {
  final dio = Dio(BaseOptions(baseUrl: 'http://example.com'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response<Map<String, dynamic>>(
            requestOptions: options,
            statusCode: status,
            data: body,
          ),
        );
      },
    ),
  );
  return dio;
}

void main() {
  test('parses analyze success', () async {
    final client = MediaApiClient(
      DioClient(
        dio: _dioWith(200, {
          'success': true,
          'platform': 'direct',
          'title': 'Demo',
          'duration': 12,
          'formats': [
            {
              'id': 'original',
              'quality': 'original',
              'format': 'mp4',
              'filesize': 100,
            },
          ],
        }),
        baseUrl: 'http://example.com',
      ),
    );
    final result = await client.analyze('https://cdn.example.com/a.mp4');
    expect(result.title, 'Demo');
    expect(result.formats, isNotEmpty);
  });

  test('maps API failure body', () async {
    final client = MediaApiClient(
      DioClient(
        dio: _dioWith(400, {
          'success': false,
          'error': {
            'code': 'unsupported_platform',
            'message': 'Nope',
          },
        }),
        baseUrl: 'http://example.com',
      ),
    );
    expect(
      () => client.analyze('https://cdn.example.com/a.mp4'),
      throwsA(isA<AppException>()),
    );
  });
}
