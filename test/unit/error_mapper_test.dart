import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/core/errors/error_mapper.dart';
import 'package:social_save/core/errors/exceptions.dart';

void main() {
  const mapper = ErrorMapper();

  test('maps timeout', () {
    final error = mapper.fromDio(
      DioException(
        requestOptions: RequestOptions(),
        type: DioExceptionType.connectionTimeout,
      ),
    );
    expect(error.code, AppErrorCode.timeout);
  });

  test('maps API error codes from JSON', () {
    final error = mapper.fromStatus(403, {
      'error': {
        'code': 'private_video',
        'message': 'Unable to access this video.',
      },
    });
    expect(error.code, AppErrorCode.privateVideo);
    expect(error.message, contains('Unable to access'));
  });

  test('maps rate limit status', () {
    expect(mapper.fromStatus(429, null).code, AppErrorCode.rateLimited);
  });

  test('maps filesystem errors to insufficient storage', () {
    final error = mapper.fromObject(
      FileSystemException('No space left on device'),
    );
    expect(error.code, AppErrorCode.insufficientStorage);
  });
}
