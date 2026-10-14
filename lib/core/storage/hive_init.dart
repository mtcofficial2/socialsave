import 'dart:async';
import 'dart:io';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:social_save/core/constants/app_constants.dart';

class HiveInit {
  const HiveInit();

  /// Test hook (--test-data): keep the box in a separate folder so a test
  /// copy can run next to the user's own SocialSave without the Hive lock.
  static String? debugDir;

  Future<Box<String>> openDownloadsBox() async {
    final dir = debugDir;
    if (dir != null) {
      await Directory(dir).create(recursive: true);
      Hive.init(dir);
    } else if (Platform.isWindows &&
        await _documentsBoxLocked(AppConstants.downloadsBoxName)) {
      // Open with starts a second process. The copy already running holds
      // the downloads box, so this one plays from a private folder.
      final fallback = await Directory.systemTemp.createTemp('socialsave_player_');
      Hive.init(fallback.path);
    } else {
      await Hive.initFlutter();
    }
    return Hive.openBox<String>(AppConstants.downloadsBoxName);
  }

  Future<bool> _documentsBoxLocked(String name) async {
    final home = Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) return false;
    final lock = File('$home\\Documents\\$name.lock');
    if (!lock.existsSync()) return false;
    RandomAccessFile? handle;
    try {
      handle = await lock.open(mode: FileMode.append);
      await handle.lock().timeout(const Duration(milliseconds: 400));
      await handle.unlock();
      return false;
    } on TimeoutException {
      return true;
    } catch (_) {
      return true;
    } finally {
      try {
        await handle?.close();
      } catch (_) {}
    }
  }
}