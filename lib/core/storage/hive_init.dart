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
    } else {
      await Hive.initFlutter();
    }
    return Hive.openBox<String>(AppConstants.downloadsBoxName);
  }
}