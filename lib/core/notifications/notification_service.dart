import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:social_save/features/chat/chat_api.dart';

const _notificationLogo = DrawableResourceAndroidBitmap('ic_notification_logo');

/// Reply typed into a chat notification. Works from the background isolate.
@pragma('vm:entry-point')
void chatNotificationBackground(NotificationResponse response) {
  DartPluginRegistrant.ensureInitialized();
  final text = response.input?.trim() ?? '';
  final payload = response.payload ?? '';
  if (response.actionId != 'reply' || text.isEmpty) return;
  unawaited(sendChatNotificationReply(payload, text));
}

String? _recentReplyKey;
DateTime? _recentReplyAt;

/// Chat payload and typed text from a notification tap.
///
/// The text is null when the person only opened the chat.
@visibleForTesting
(String?, String?) chatNotificationReplyOf(NotificationResponse response) {
  return (_chatPayload(response), _replyText(response));
}

/// Sends [text] into the chat named by a `chat|threadId|name` payload.
Future<void> sendChatNotificationReply(String payload, String text) async {
  final clean = text.trim();
  final parts = payload.split('|');
  if (parts.length < 2 || parts.first != 'chat') return;
  final id = parts[1].trim();
  if (id.isEmpty || clean.isEmpty) return;
  final key = '$id|$clean';
  final now = DateTime.now();
  if (_recentReplyKey == key &&
      _recentReplyAt != null &&
      now.difference(_recentReplyAt!) < const Duration(seconds: 4)) {
    return;
  }
  _recentReplyKey = key;
  _recentReplyAt = now;
  try {
    final sent = await ChatApi().send(id, clean);
    final keep = NotificationService.onReplySent;
    if (keep != null) await keep(id, sent);
  } catch (_) {
    if (_recentReplyKey == key) {
      _recentReplyKey = null;
      _recentReplyAt = null;
    }
    await NotificationService().showReplyFailed();
  }
}

List<WindowsImage> _windowsLogo() {
  return [
    WindowsImage(
      WindowsImage.getAssetUri('assets/brand/icon_192.png'),
      altText: 'Social Save',
      placement: WindowsImagePlacement.appLogoOverride,
      crop: WindowsImageCrop.circle,
    ),
  ];
}

String? _replyText(NotificationResponse response) {
  final typed = response.input?.trim() ?? '';
  if (typed.isNotEmpty) return typed;
  final raw = response.data['reply'];
  if (raw is String && raw.trim().isNotEmpty) return raw.trim();
  return null;
}

String? _chatPayload(NotificationResponse response) {
  final payload = response.payload ?? '';
  if (payload.startsWith('chat|')) return payload;
  final action = response.actionId ?? '';
  if (action.startsWith('chat|')) return action;
  return null;
}

class NotificationService {
  NotificationService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  /// Set by the copied-link watcher: (actionId, payload) of a tapped toast.
  static void Function(String? actionId, String? payload)? onResponse;

  /// 1.0.46: the "Phone connected by USB" toast was tapped.
  static void Function()? onUsbShare;

  /// A chat toast was tapped. The payload is chat|threadId|username.
  static void Function(String payload)? onChatOpen;
  static String? _pendingChat;

  /// A reply typed into a notification was accepted by the server.
  /// The background isolate does not set this, so only the open app saves it.
  static Future<void> Function(String threadId, ChatMessage message)?
  onReplySent;

  /// Remembers [open] and delivers a tap that arrived before the chat host.
  static void attachChatOpen(void Function(String payload) open) {
    onChatOpen = open;
    final pending = _pendingChat;
    _pendingChat = null;
    if (pending != null) open(pending);
  }

  /// Drops [open] when that host goes away.
  static void detachChatOpen(void Function(String payload) open) {
    if (onChatOpen == open) onChatOpen = null;
  }

  /// Windows toast: a phone was plugged in by USB; "Share files" opens the session screen.
  Future<void> showUsbShare(String name) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    if (!_initialized) await init();
    await _showWindows(
      0x5553b,
      'Connected to $name by USB',
      'Share files both ways over the cable.',
      payload: 'usbshare|open',
      actions: [
        const WindowsAction(content: 'Share files', arguments: 'usbshare|open'),
      ],
    );
  }

  /// Windows toast with Download / Dismiss buttons for a copied video link.
  Future<void> showLinkOffer({
    required String url,
    required String subtitle,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    if (!_initialized) await init();
    await _showWindows(
      url.hashCode & 0x7fffffff,
      'Download copied video?',
      subtitle,
      payload: url,
      actions: [
        WindowsAction(content: 'Download', arguments: 'download|$url'),
        WindowsAction(content: 'Dismiss', arguments: 'dismiss|$url'),
      ],
    );
  }

  /// Logo first. A missing picture still shows the toast and its buttons.
  Future<void> _showWindows(
    int id,
    String title,
    String body, {
    String? payload,
    List<WindowsInput> inputs = const [],
    List<WindowsAction> actions = const [],
  }) async {
    try {
      await _plugin.show(
        id,
        title,
        body,
        NotificationDetails(
          windows: WindowsNotificationDetails(
            images: _windowsLogo(),
            inputs: inputs,
            actions: actions,
          ),
        ),
        payload: payload,
      );
    } catch (_) {
      try {
        await _plugin.show(
          id,
          title,
          body,
          NotificationDetails(
            windows: WindowsNotificationDetails(
              inputs: inputs,
              actions: actions,
            ),
          ),
          payload: payload,
        );
      } catch (_) {}
    }
  }

  Future<void> init() async {
    if (kIsWeb) return; // The browser build shows no system notifications.
    if (_initialized) {
      return;
    }
    const android = AndroidInitializationSettings('ic_notification');
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
      await _plugin
          .initialize(
            const InitializationSettings(
              android: android,
              iOS: ios,
              windows: windows,
            ),
            onDidReceiveNotificationResponse: _onResponse,
            onDidReceiveBackgroundNotificationResponse:
                chatNotificationBackground,
          )
          .timeout(const Duration(seconds: 3));
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final opened = launch?.notificationResponse;
      if (launch?.didNotificationLaunchApp == true && opened != null) {
        _onResponse(opened);
      }
    } catch (_) {
      // A missing icon or a slow plugin must not leave the app on the
      // opening screen. Notifications stay quiet until the next launch.
    }
    _initialized = true;
  }

  Future<void> requestPermission() async {
    if (kIsWeb) return; // The browser build shows no system notifications.
    await init();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.requestNotificationsPermission();
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    await ios?.requestPermissions(alert: true, badge: true, sound: true);
  }

  /// Shown when a reply typed into a notification did not reach the server.
  Future<void> showReplyFailed() async {
    if (kIsWeb) return;
    if (!_initialized) await init();
    const body = 'Open the chat and send it again.';
    if (defaultTargetPlatform == TargetPlatform.windows) {
      await _showWindows(0x52454641, 'Message not sent', body);
      return;
    }
    try {
      await _plugin.show(
        0x52454641,
        'Message not sent',
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'chats_v2',
            'Chats',
            channelDescription: 'New messages',
            icon: 'ic_notification',
            largeIcon: _notificationLogo,
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(presentAlert: true),
        ),
      );
    } catch (_) {}
  }

  Future<void> showChat({
    required String threadId,
    required String title,
    required String body,
    bool sound = true,
  }) async {
    if (kIsWeb || threadId.isEmpty) return;
    if (!_initialized) await init();
    final payload = 'chat|$threadId|$title';
    final id = threadId.hashCode & 0x7fffffff;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      await _showWindows(
        id,
        title,
        body,
        payload: payload,
        inputs: const [
          WindowsTextInput(id: 'reply', placeHolderContent: 'Message'),
        ],
        actions: [
          WindowsAction(content: 'Reply', arguments: payload, inputId: 'reply'),
        ],
      );
      return;
    }
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          sound ? 'chats_v2' : 'chats_quiet',
          'Chats',
          channelDescription: 'New messages',
          icon: 'ic_notification',
          largeIcon: _notificationLogo,
          importance: Importance.high,
          priority: Priority.high,
          playSound: sound,
          enableVibration: sound,
          category: AndroidNotificationCategory.message,
          actions: const <AndroidNotificationAction>[
            AndroidNotificationAction(
              'reply',
              'Reply',
              // Opening the app sends the reply on the running chat connection.
              // A background reply keeps Android's spinner up and the message
              // never leaves.
              showsUserInterface: true,
              cancelNotification: true,
              allowGeneratedReplies: true,
              semanticAction: SemanticAction.reply,
              inputs: <AndroidNotificationActionInput>[
                AndroidNotificationActionInput(label: 'Message'),
              ],
            ),
          ],
        ),
        iOS: DarwinNotificationDetails(presentSound: sound, presentAlert: true),
      ),
      payload: payload,
    );
  }

  Future<void> showDownloadComplete({
    required String id,
    required String title,
  }) async {
    if (kIsWeb) return; // The browser build shows no system notifications.
    if (!_initialized) {
      await init();
    }
    if (defaultTargetPlatform == TargetPlatform.windows) {
      await _showWindows(id.hashCode & 0x7fffffff, 'Download complete', title);
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
          icon: 'ic_notification',
          largeIcon: _notificationLogo,
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
    if (kIsWeb) return; // The browser build shows no system notifications.
    if (!_initialized) {
      await init();
    }
    if (defaultTargetPlatform == TargetPlatform.windows) {
      await _showWindows(id.hashCode & 0x7fffffff, 'Download failed', title);
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
          icon: 'ic_notification',
          largeIcon: _notificationLogo,
          importance: Importance.defaultImportance,
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }

  static void _onResponse(NotificationResponse response) {
    final probe = (response.actionId ?? '').isNotEmpty
        ? response.actionId!
        : (response.payload ?? '');
    if (probe.startsWith('usbshare')) {
      onUsbShare?.call();
      return;
    }
    final payload = _chatPayload(response);
    final reply = _replyText(response);
    if (payload != null && reply != null) {
      _openChat(payload);
      unawaited(sendChatNotificationReply(payload, reply));
      return;
    }
    if (payload != null) {
      _openChat(payload);
      return;
    }
    onResponse?.call(response.actionId, response.payload);
  }

  static void _openChat(String payload) {
    final open = onChatOpen;
    if (open == null) {
      _pendingChat = payload;
      return;
    }
    open(payload);
  }
}
