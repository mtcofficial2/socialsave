import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:social_save/core/config/env_config.dart';
import 'package:social_save/core/notifications/notification_photo_io.dart'
    if (dart.library.html) 'package:social_save/core/notifications/notification_photo_stub.dart';
import 'package:social_save/core/notifications/windows_toast_setup_stub.dart'
    if (dart.library.ffi) 'package:social_save/core/notifications/windows_toast_setup.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_ui.dart';

const _notificationLogo = DrawableResourceAndroidBitmap('ic_notification_logo');

/// Reply typed into a chat notification. Works from the background isolate.
@pragma('vm:entry-point')
void chatNotificationBackground(NotificationResponse response) {
  DartPluginRegistrant.ensureInitialized();
  final muted = chatNotificationMuteThread(response);
  if (muted != null) {
    unawaited(ChatInboxFilter.setMuted(muted, on: true));
    return;
  }
  final text = response.input?.trim() ?? '';
  final payload = response.payload ?? '';
  if (response.actionId != 'reply' || text.isEmpty) return;
  unawaited(sendChatNotificationReply(payload, text));
}

final _chatThreadId = RegExp(r'^[A-Za-z0-9]{2,80}$');

/// Thread id from a Mute button on a chat notification, or null.
@visibleForTesting
String? chatNotificationMuteThread(NotificationResponse response) {
  for (final raw in [response.actionId, response.payload]) {
    final value = raw?.trim() ?? '';
    if (!value.startsWith('mute|')) continue;
    final id = value.substring(5).trim();
    if (_chatThreadId.hasMatch(id)) return id;
  }
  return null;
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

/// Saves a profile photo the next time a chat screen loads it, so a later
/// message notification already has the face.
void keepChatFacesForNotifications() {
  ChatPhotos.onStored ??= (name, rev, bytes) {
    unawaited(storeNotificationPhoto(name, rev, bytes));
  };
}

Future<List<WindowsImage>> _windowsFace(
  Uint8List? picture,
  String fileName,
  String alt,
) async {
  if (picture == null || picture.isEmpty) return _windowsLogo();
  try {
    final path = await saveNotificationPhoto(picture, fileName);
    if (path != null && path.isNotEmpty) {
      return [
        WindowsImage(
          Uri.file(path),
          altText: alt.trim().isEmpty ? fileName : alt.trim(),
          placement: WindowsImagePlacement.appLogoOverride,
          crop: WindowsImageCrop.circle,
        ),
      ];
    }
  } catch (_) {}
  return _windowsLogo();
}

/// `chat|threadId|username` or `chat|threadId|username|name you see`.
/// The photo and the open action stay on the username.
String chatNotificationPayload({
  required String threadId,
  required String title,
  String username = '',
}) {
  final handle = username.trim().isEmpty ? title.trim() : username.trim();
  final label = title.trim();
  if (label.isEmpty || label == handle) return 'chat|$threadId|$handle';
  return 'chat|$threadId|$handle|$label';
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

const _androidChatNotify = MethodChannel('socialsave/chat_notify');

/// A typed reply stays on the current screen. Only a tap with no text
/// opens that chat.
@visibleForTesting
bool chatNotificationOpensChat(NotificationResponse response) {
  if (chatNotificationMuteThread(response) != null) return false;
  if (_chatPayload(response) == null) return false;
  return _replyText(response) == null;
}

/// A toast that should open the download sheet. An incoming call is not a link.
String? linkOfferFromToast(String? actionId, String? payload) {
  final picked = (actionId != null && actionId.contains('|')) ? actionId : (payload ?? '');
  final text = picked.trim();
  if (text.isEmpty || text.startsWith('call|') || text.startsWith('dismiss|')) {
    return null;
  }
  if (text.startsWith('download|')) {
    final url = text.substring('download|'.length).trim();
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    return null;
  }
  if (text.startsWith('http://') || text.startsWith('https://')) return text;
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

  /// A Windows toast for an incoming call was clicked. The window comes forward.
  static void Function()? onCallOpen;
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
  /// Returns false when Windows refused the toast.
  Future<bool> _showWindows(
    int id,
    String title,
    String body, {
    String? payload,
    List<WindowsInput> inputs = const [],
    List<WindowsAction> actions = const [],
    List<WindowsImage>? images,
    bool silent = false,
  }) async {
    final shown = images ?? _windowsLogo();
    final audio = silent ? WindowsNotificationAudio.silent() : null;
    try {
      await _plugin.show(
        id,
        title,
        body,
        NotificationDetails(
          windows: WindowsNotificationDetails(
            images: shown,
            inputs: inputs,
            actions: actions,
            audio: audio,
          ),
        ),
        payload: payload,
      );
      return true;
    } catch (_) {
      if (images != null) {
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
                audio: audio,
              ),
            ),
            payload: payload,
          );
          return true;
        } catch (_) {}
      }
      try {
        await _plugin.show(
          id,
          title,
          body,
          NotificationDetails(
            windows: WindowsNotificationDetails(
              inputs: inputs,
              actions: actions,
              audio: audio,
            ),
          ),
          payload: payload,
        );
        return true;
      } catch (_) {}
    }
    return false;
  }

  Future<void> init() async {
    keepChatFacesForNotifications();
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
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      ensureWindowsNotificationIdentity();
    }
    final windows = WindowsInitializationSettings(
      appName: 'SocialSave',
      appUserModelId: windowsNotificationAppId,
      guid: '6f1c2b8e-4d3a-4a5e-9b7c-2e8f0a1d5c43',
      iconPath: windowsNotificationIconPath(),
    );
    if (defaultTargetPlatform == TargetPlatform.android) {
      _androidChatNotify.setMethodCallHandler((call) async {
        if (call.method == 'opened' && call.arguments is String) {
          _openChat(call.arguments as String);
        } else if (call.method == 'muted' && call.arguments is String) {
          final id = (call.arguments as String).trim();
          if (_chatThreadId.hasMatch(id)) {
            unawaited(ChatInboxFilter.setMuted(id, on: true));
          }
        }
      });
      try {
        final pending = await _androidChatNotify.invokeMethod<String>('pending');
        if (pending != null && pending.startsWith('chat|')) _openChat(pending);
      } catch (_) {}
    }
    try {
      await _plugin
          .initialize(
            InitializationSettings(
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

  Future<bool> _postAndroidChat({
    required int id,
    required String title,
    required String body,
    required String payload,
    required bool sound,
    required bool silent,
    Uint8List? picture,
  }) async {
    final token = await ChatSession.token() ?? '';
    Future<void> sendWithToken(Uint8List? face) {
      return _androidChatNotify.invokeMethod<void>('show', <String, Object?>{
        'id': id,
        'title': title,
        'body': body,
        'payload': payload,
        'sound': sound,
        'silent': silent,
        'api': EnvConfig.apiBaseUrl,
        'token': token,
        if (face != null && face.isNotEmpty) 'picture': face,
      });
    }

    try {
      await sendWithToken(picture);
      return true;
    } catch (_) {}
    if (picture != null && picture.isNotEmpty) {
      try {
        await sendWithToken(null);
        return true;
      } catch (_) {}
    }
    return false;
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

  Future<bool> showChat({
    required String threadId,
    required String title,
    required String body,
    String username = '',
    bool sound = true,
    bool silent = false,
    Uint8List? picture,
  }) async {
    if (kIsWeb || threadId.isEmpty) return false;
    if (!_initialized) await init();
    final handle = username.trim().isEmpty ? title.trim() : username.trim();
    final payload = chatNotificationPayload(
      threadId: threadId,
      title: title,
      username: handle,
    );
    final id = threadId.hashCode & 0x7fffffff;
    final alert = sound && !silent;
    if (defaultTargetPlatform == TargetPlatform.android) {
      // The plugin notification has no reply box. One UI then says to open
      // the app. Stay on the native notification, and try once without the
      // photo if the first post is refused.
      final posted = await _postAndroidChat(
        id: id,
        title: title,
        body: body,
        payload: payload,
        sound: sound,
        silent: silent,
        picture: picture,
      );
      return posted;
    }
    if (defaultTargetPlatform == TargetPlatform.windows) {
      return _showWindows(
        id,
        title,
        body,
        payload: payload,
        inputs: const [
          WindowsTextInput(id: 'reply', placeHolderContent: 'Message'),
        ],
        actions: [
          WindowsAction(content: 'Reply', arguments: payload, inputId: 'reply'),
          WindowsAction(content: 'Mute', arguments: 'mute|$threadId'),
        ],
        images: await _windowsFace(picture, handle, title),
        silent: silent,
      );
    }
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          alert ? 'chats_v2' : 'chats_quiet',
          'Chats',
          channelDescription: 'New messages',
          icon: 'ic_notification',
          largeIcon: picture != null && picture.isNotEmpty
              ? ByteArrayAndroidBitmap(picture)
              : null,
          importance: Importance.high,
          priority: Priority.high,
          playSound: alert,
          enableVibration: alert,
          onlyAlertOnce: true,
          category: AndroidNotificationCategory.message,
        ),
        iOS: DarwinNotificationDetails(
          presentSound: alert,
          presentAlert: true,
        ),
      ),
      payload: payload,
    );
    return true;
  }

  static const incomingCallId = 910085;

  /// A ringing banner. The phone ringtone itself is played separately so the
  /// notification sound does not cut the ring short. Windows has no call
  /// channel, so the same words go out as a toast.
  Future<void> showIncomingCall(String name) async {
    if (kIsWeb) return;
    if (!_initialized) await init();
    final who = name.trim().isEmpty ? 'Audio call' : name.trim();
    if (defaultTargetPlatform == TargetPlatform.windows) {
      await _showWindows(
        incomingCallId,
        who,
        'Incoming audio call',
        payload: 'call|incoming',
      );
      return;
    }
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'calls_v1',
        'Calls',
        channelDescription: 'Incoming audio calls',
        icon: 'ic_notification',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.call,
        fullScreenIntent: false,
        ongoing: true,
        playSound: false,
        enableVibration: true,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.timeSensitive,
      ),
    );
    await _plugin.show(
      incomingCallId,
      who,
      'Incoming audio call',
      details,
      payload: 'call|incoming',
    );
  }

  Future<void> cancelIncomingCall() => _plugin.cancel(incomingCallId);

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
    if (probe.startsWith('call|') || (response.payload ?? '').startsWith('call|')) {
      onCallOpen?.call();
      return;
    }
    final muteThread = chatNotificationMuteThread(response);
    if (muteThread != null) {
      unawaited(ChatInboxFilter.setMuted(muteThread, on: true));
      return;
    }
    final payload = _chatPayload(response);
    final reply = _replyText(response);
    if (payload != null && reply != null) {
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
