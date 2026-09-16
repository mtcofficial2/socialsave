import 'package:flutter/services.dart';

class MediaStoreService {
  static const _channel = MethodChannel('socialsave/media');

  Future<String?> publishToDownloads({
    required String sourcePath,
    required String fileName,
    String mimeType = 'video/mp4',
  }) async {
    try {
      final result = await _channel.invokeMethod<String>('saveToDownloads', {
        'path': sourcePath,
        'name': fileName,
        'mime': mimeType,
      });
      return result;
    } catch (_) {
      return null;
    }
  }

  Future<void> scanFile(String path) async {
    try {
      await _channel.invokeMethod<void>('scanFile', {'path': path});
    } catch (_) {
      // Best-effort indexing for Gallery / Files.
    }
  }
}
