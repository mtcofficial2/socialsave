import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  NotificationService({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) {
      return;
    }
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const windows = WindowsInitializationSettings(
      appName: 'SocialSave',
      appUserModelId: 'com.socialsave.SocialSave',
      guid: '6f1c2b8e-4d3a-4a5e-9b7c-2e8f0a1d5c43',
    );
    try {
      await _plugin.initialize(
        const InitializationSettings(android: android, iOS: ios, windows: windows),
      );
    } catch (_) {
      // Desktop notifications are best-effort; never block app start.
      if (defaultTargetPlatform != TargetPlatform.windows) rethrow;
    }
    _initialized = true;
  }

  Future<void> requestPermission() async {
    await init();
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    await ios?.requestPermissions(alert: true, badge: true, sound: true);
  }

  Future<void> showDownloadComplete({
    required String id,
    required String title,
  }) async {
    if (!_initialized) {
      await init();
    }
    if (defaultTargetPlatform == TargetPlatform.windows) {
      try {
        await _plugin.show(
          id.hashCode & 0x7fffffff,
          'Download complete',
          title,
          null,
        );
      } catch (_) {}
      return;
    }
    await _plugin.show(
      id.hashCode,
      'Download complete',
      title,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'downloads',
          'Downloads',
          channelDescription: 'Finished SocialSave downloads',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }

  Future<void> showDownloadFailed({
    required String id,
    required String title,
  }) async {
    if (!_initialized) {
      await init();
    }
    if (defaultTargetPlatform == TargetPlatform.windows) {
      try {
        await _plugin.show(
          id.hashCode & 0x7fffffff,
          'Download failed',
          title,
          null,
        );
      } catch (_) {}
      return;
    }
    await _plugin.show(
      id.hashCode,
      'Download failed',
      title,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'downloads',
          'Downloads',
          channelDescription: 'Finished SocialSave downloads',
          importance: Importance.defaultImportance,
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }
}
