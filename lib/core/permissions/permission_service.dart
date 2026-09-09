import 'dart:io';

import 'package:permission_handler/permission_handler.dart';
import 'package:social_save/core/storage/download_path_service.dart';

class PermissionService {
  const PermissionService();

  Future<bool> ensureDownloadPermissions(DownloadLocation location) async {
    if (location == DownloadLocation.appStorage) {
      return true;
    }
    if (Platform.isIOS) {
      final photos = await Permission.photosAddOnly.request();
      return photos.isGranted || photos.isLimited;
    }
    if (Platform.isAndroid) {
      final videos = await Permission.videos.request();
      if (videos.isGranted || videos.isLimited) {
        return true;
      }
      final storage = await Permission.storage.request();
      return storage.isGranted;
    }
    return true;
  }
}
