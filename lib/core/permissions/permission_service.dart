import 'package:social_save/core/platform/plat.dart';

import 'package:permission_handler/permission_handler.dart';
import 'package:social_save/core/storage/download_path_service.dart';

class PermissionService {
  const PermissionService();

  Future<bool> ensureDownloadPermissions(DownloadLocation location) async {
    if (location == DownloadLocation.appStorage) {
      return true;
    }
    if (Plat.isIOS) {
      final photos = await Permission.photosAddOnly.request();
      return photos.isGranted || photos.isLimited;
    }
    if (Plat.isAndroid) {
      // Already granted (or limited): never open a request, which can hang with no visible activity.
      if (await Permission.videos.isGranted || await Permission.storage.isGranted) return true;
      final videos = await Permission.videos.request();
      final storage = await Permission.storage.request();
      if (videos.isGranted || videos.isLimited || storage.isGranted) {
        return true;
      }
      return true;
    }
    return true;
  }
}
