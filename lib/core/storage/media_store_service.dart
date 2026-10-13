import 'package:flutter/services.dart';

class MediaStoreService {
  static const _channel = MethodChannel('socialsave/media');

  static bool _isPublic(String path) {
    final x = path.replaceFirst('/sdcard/', '/storage/emulated/0/');
    return x.startsWith('/storage/emulated/0/Download/') ||
        x.startsWith('/storage/emulated/0/Movies/') ||
        x.startsWith('/storage/emulated/0/DCIM/');
  }

  Future<String?> publishToDownloads({
    required String sourcePath,
    required String fileName,
    String mimeType = 'video/mp4',
  }) async {
    if (_isPublic(sourcePath)) {
      // Already saved publicly: just index it, never make a second copy.
      await scanFile(sourcePath);
      return sourcePath;
    }
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

  Future<String?> publishToGallery({
    required String sourcePath,
    required String fileName,
    String mimeType = 'video/mp4',
  }) async {
    try {
      final result = await _channel.invokeMethod<String>('saveToGallery', {
        'path': sourcePath,
        'name': fileName,
        'mime': mimeType,
      });
      return result;
    } catch (_) {
      return publishToDownloads(
        sourcePath: sourcePath,
        fileName: fileName,
        mimeType: mimeType,
      );
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
