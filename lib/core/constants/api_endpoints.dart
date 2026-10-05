class ApiEndpoints {
  const ApiEndpoints._();

  static const String apiPrefix = '/api/v1';

  static const String health = '/health';
  static const String platforms = '$apiPrefix/platforms';
  static const String analyze = '$apiPrefix/analyze';
  static const String download = '$apiPrefix/download';
  static const String playlist = '$apiPrefix/playlist';
  static const String summarize = '$apiPrefix/summarize';
  static const String pair = '$apiPrefix/pair';

  static String pairCode(String code) => '$apiPrefix/pair/$code';

  static String downloadStatus(String id) => '$apiPrefix/download/$id';
  static String file(String token) => '$apiPrefix/files/$token';
}
