import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/notifications/notification_service.dart';
import 'package:social_save/core/platform/media_events.dart';
import 'package:social_save/core/permissions/permission_service.dart';
import 'package:social_save/core/storage/download_path_service.dart';
import 'package:social_save/core/storage/hive_init.dart';
import 'package:social_save/features/downloads/data/datasources/download_history_store.dart';
import 'package:social_save/features/library/phone_handoff.dart';
import 'package:social_save/features/library/presentation/library_screen.dart' show vaultServiceProvider;
import 'package:social_save/features/library/vault_service.dart';
import 'package:social_save/features/settings/data/datasources/settings_store.dart';

/// No activity to ask: saving goes through MediaStore, which needs no permission.
class _HeadlessPermissions extends PermissionService {
  const _HeadlessPermissions();
  @override
  Future<bool> ensureDownloadPermissions(DownloadLocation location) async => true;
}

/// Headless entrypoint (Android): started by HeadlessEngine.kt with no activity.
/// Runs the same analyse / enqueue / download pipeline as the app and reports
/// progress to the floating card through the `socialsave/media` channel.
@pragma('vm:entry-point')
Future<void> bgMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final box = await const HiveInit().openDownloadsBox();
  final prefs = await SharedPreferences.getInstance();
  final settingsStore = SharedPreferencesSettingsStore(prefs);
  final settings = await settingsStore.load();
  final notifications = NotificationService();
  await notifications.init();
  final container = ProviderContainer(
    overrides: [
      downloadsRepositoryProvider.overrideWithValue(HiveDownloadHistoryStore(box)),
      settingsRepositoryProvider.overrideWithValue(settingsStore),
      initialSettingsProvider.overrideWithValue(settings),
      notificationServiceProvider.overrideWithValue(notifications),
      vaultServiceProvider.overrideWithValue(VaultService(prefs)),
      permissionServiceProvider.overrideWithValue(const _HeadlessPermissions()),
    ],
  );
  installOverlayHandlers(() => container);
  await MediaEvents.channel.invokeMethod<void>('bgReady');
}