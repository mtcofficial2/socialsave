import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/app.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/notifications/notification_service.dart';
import 'package:social_save/core/storage/hive_init.dart';
import 'package:social_save/features/downloads/data/datasources/download_history_store.dart';
import 'package:social_save/features/settings/data/datasources/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final box = await const HiveInit().openDownloadsBox();
  final prefs = await SharedPreferences.getInstance();
  final settingsStore = SharedPreferencesSettingsStore(prefs);
  final settings = await settingsStore.load();
  final notifications = NotificationService();
  await notifications.init();

  runApp(
    ProviderScope(
      overrides: [
        downloadsRepositoryProvider.overrideWithValue(
          HiveDownloadHistoryStore(box),
        ),
        settingsRepositoryProvider.overrideWithValue(settingsStore),
        initialSettingsProvider.overrideWithValue(settings),
        notificationServiceProvider.overrideWithValue(notifications),
      ],
      child: const SocialSaveApp(),
    ),
  );
}
