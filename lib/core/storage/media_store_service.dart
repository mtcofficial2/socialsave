import 'package:flutter/services.dart';

class MediaStoreService {
  static const _channel = MethodChannel('socialsave/media');

  static bool _isPublic(String path) {
    final x = path.replaceFirst('/sdcard/', '/storage/emulated/0/');
    return x.startsWith('/storage/emulated/0/Download/') ||
        x.startsWith('/storage/emulated/0/Movies/') ||
        x.startsWith('/storage/emulated/0/DCIM/');
  }

  /// True when this video is one TikTok may refuse. False when it is already
  /// a normal file, or when the phone cannot tell.
  Future<bool> needsTiktokWork(String path) async {
    try {
      return await _channel.invokeMethod<bool>('needsTiktokWork', {'path': path}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Asks on the floating card, or on the bubble when that card cannot show.
  /// Null means neither is up, so the app shows its own question.
  Future<bool?> askTiktokOnBubble(String title) async {
    try {
      return await _channel.invokeMethod<bool>('askTiktok', {'title': title});
    } catch (_) {
      return null;
    }
  }

  /// Rewrites a video TikTok cannot decode into 30 fps H.264 and AAC-LC.
  /// Landscape fits in 1920×1080. Portrait stays portrait. Returns the path to keep.
  Future<String?> makeUploadReady(String path) async {
    try {
      return await _channel.invokeMethod<String>('makeUploadReady', {'path': path});
    } catch (_) {
      return path;
    }
  }

  /// Stops a TikTok rewrite that is still running, for example when a download is cancelled.
  Future<void> cancelUploadPrep() async {
    try {
      await _channel.invokeMethod<void>('cancelUploadPrep');
    } catch (_) {}
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
