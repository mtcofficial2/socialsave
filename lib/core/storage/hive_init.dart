import 'package:hive_flutter/hive_flutter.dart';
import 'package:social_save/core/constants/app_constants.dart';

class HiveInit {
  const HiveInit();

  Future<Box<String>> openDownloadsBox() async {
    await Hive.initFlutter();
    return Hive.openBox<String>(AppConstants.downloadsBoxName);
  }
}
