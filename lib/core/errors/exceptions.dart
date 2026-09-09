enum AppErrorCode {
  invalidUrl,
  unsupportedPlatform,
  privateVideo,
  removedVideo,
  platformUnavailable,
  platformDisabled,
  downloadNotPermitted,
  networkUnavailable,
  serverError,
  timeout,
  downloadInterrupted,
  insufficientStorage,
  permissionDenied,
  unsupportedFormat,
  fileTooLarge,
  unauthorized,
  rateLimited,
  unknown,
}

class AppException implements Exception {
  const AppException({
    required this.code,
    required this.message,
    this.cause,
    this.statusCode,
  });

  final AppErrorCode code;
  final String message;
  final Object? cause;
  final int? statusCode;

  @override
  String toString() => 'AppException($code, $statusCode): $message';
}
