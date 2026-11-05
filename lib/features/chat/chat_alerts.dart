import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/notifications/notification_photo_io.dart'
    if (dart.library.html) 'package:social_save/core/notifications/notification_photo_stub.dart';
import 'package:social_save/core/notifications/notification_service.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/chat/chat_alert_policy.dart';
import 'package:social_save/features/chat/chat_call.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/features/chat/chat_prefs.dart';
import 'package:social_save/features/chat/chat_history.dart';
import 'package:social_save/features/chat/chat_live.dart';
import 'package:social_save/features/chat/chat_ui.dart';
import 'package:social_save/features/library/desktop_tray.dart';
import 'package:social_save/shared/routing/app_router.dart';

/// A sound plus a notification. Android's system "alert" sound does nothing,
/// so an open app plays the phone's notification tone itself and keeps the
/// banner quiet. In the background the notification channel sounds. Windows
/// shows a toast. A beep is only the fallback when that toast cannot be shown.
void chatAlertNow({
  required String threadId,
  required String title,
  required String body,
  String username = '',
  int photoRev = 0,
}) {
  unawaited(
    _deliverChatAlert(
      threadId: threadId,
      title: title,
      body: body,
      username: username,
      photoRev: photoRev,
    ),
  );
}

Future<void> _deliverChatAlert({
  required String threadId,
  required String title,
  required String body,
  required String username,
  required int photoRev,
}) async {
  await ChatPrefs.ensure();
  final tones = ChatPrefs.soundAllowed(threadId);
  final here = chatUserIsHere(
    life: WidgetsBinding.instance.lifecycleState,
    screenOn: await _androidScreenOn(),
  );
  if (tones && Plat.isAndroid && here) {
    unawaited(_playPhoneTone());
  }
  await _postChatAlert(
    threadId: threadId,
    title: title,
    body: body,
    username: username.trim().isEmpty ? title : username.trim(),
    photoRev: photoRev,
    sound: tones && !here,
  );
}

/// The phone screen is on. Other platforms, and a failed check, count as on.
Future<bool> _androidScreenOn() async {
  if (!Plat.isAndroid) return true;
  try {
    final on = await const MethodChannel(
      'socialsave/chat_listen',
    ).invokeMethod<bool>('screenOn');
    return on != false;
  } catch (_) {
    return true;
  }
}

final Map<String, int> _alertToken = {};

bool _sameBytes(Uint8List a, Uint8List b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A face already on this device. The network fetch must not hold the banner.
Future<({Uint8List? bytes, bool exact})> _savedFace(
  String username,
  int photoRev,
) async {
  if (username.isEmpty || username == 'New message') {
    return (bytes: null, exact: true);
  }
  if (photoRev > 0) {
    final known = ChatPhotos.cached(username, photoRev);
    if (known != null && known.isNotEmpty) {
      return (bytes: known, exact: true);
    }
  }
  try {
    final disk = await loadNotificationPhoto(username, photoRev);
    if (disk.bytes != null && disk.bytes!.isNotEmpty) return disk;
  } catch (_) {}
  final any = ChatPhotos.anyCached(username);
  if (any != null && any.isNotEmpty) {
    return (bytes: any, exact: false);
  }
  return (bytes: null, exact: false);
}

Future<void> _postChatAlert({
  required String threadId,
  required String title,
  required String body,
  required String username,
  required int photoRev,
  required bool sound,
}) async {
  keepChatFacesForNotifications();
  final token = (_alertToken[threadId] ?? 0) + 1;
  _alertToken[threadId] = token;
  final saved = await _savedFace(username, photoRev);
  if (_alertToken[threadId] != token) return;
  final shown = await NotificationService().showChat(
    threadId: threadId,
    title: title,
    body: body,
    username: username,
    sound: sound,
    picture: saved.bytes,
  );
  if (ChatPrefs.messageSound &&
      !shown &&
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.windows) {
    unawaited(SystemSound.play(SystemSoundType.alert));
  }
  if (saved.exact || username.isEmpty || username == 'New message') return;
  try {
    final later = await ChatPhotos.forAlert(username, photoRev);
    if (later == null || later.isEmpty) return;
    if (_alertToken[threadId] != token) return;
    final shown = saved.bytes;
    if (shown != null && _sameBytes(shown, later)) return;
    await NotificationService().showChat(
      threadId: threadId,
      title: title,
      body: body,
      username: username,
      sound: sound,
      silent: true,
      picture: later,
    );
  } catch (_) {}
}

Future<void> _playPhoneTone() async {
  try {
    await const MethodChannel(
      'socialsave/media',
    ).invokeMethod<void>('playNotificationSound');
  } catch (_) {}
}

/// One inbox check for the whole app. The open chat list skips its own fetch
/// when this one just ran, so there is still a single poll.
class ChatAlerts {
  static DateTime? lastInbox;
  static String openThread = '';
  static bool seeded = false;
  static final Map<String, int> seen = {};
  static final Map<String, int> photoRevs = {};
  static final Map<String, String> labels = {};

  static void reset() {
    lastInbox = null;
    seeded = false;
    seen.clear();
    photoRevs.clear();
    labels.clear();
    openThread = '';
    ChatLive.instance.stop();
    unawaited(ChatPresence.sync());
  }

  static void holdThread(String threadId) {
    if (threadId.isEmpty) return;
    openThread = threadId;
  }

  static void releaseThread(String threadId) {
    if (openThread == threadId) openThread = '';
  }

  static void observe(
    List<ChatThreadSummary> items, {
    required String me,
    required bool notify,
    bool holdOpen = true,
    void Function(ChatThreadSummary item, String body)? alert,
  }) {
    lastInbox = DateTime.now();
    for (final item in items) {
      if (item.id.isEmpty) continue;
      final label = item.label.trim();
      if (label.isNotEmpty) labels[item.id] = label;
      if (item.photoRev <= 0) continue;
      photoRevs[item.id] = item.photoRev;
    }
    if (!seeded) {
      for (final item in items) {
        if (item.id.isEmpty) continue;
        final prev = seen[item.id] ?? 0;
        seen[item.id] = item.lastId > prev ? item.lastId : prev;
      }
      seeded = true;
      return;
    }
    for (final item in items) {
      if (item.id.isEmpty) continue;
      final prev = seen[item.id] ?? 0;
      final grew = item.lastId > prev && item.lastId > 0;
      seen[item.id] = item.lastId > prev ? item.lastId : prev;
      if (!notify || !grew || alert == null) continue;
      if (item.lastFrom.isEmpty || chatSameUser(item.lastFrom, me)) continue;
      if (holdOpen && item.id == openThread) continue;
      if (ChatInboxFilter.isMuted(item.id)) continue;
      alert(item, chatAlertBody(item.lastText));
    }
  }
}

/// Phone foreground service and Windows tray, while a chat account is signed in.
class ChatPresence {
  ChatPresence._();

  static bool _on = false;
  static bool _batteryAsked = false;

  static Future<void> sync() async {
    final token = await ChatSession.token();
    final signedIn = token != null && token.isNotEmpty;
    if (Plat.isWindows) {
      DesktopTray.messages(signedIn);
      _on = signedIn;
      return;
    }
    if (!Plat.isAndroid) {
      _on = signedIn;
      return;
    }
    if (signedIn == _on) return;
    _on = signedIn;
    try {
      await const MethodChannel(
        'socialsave/chat_listen',
      ).invokeMethod<void>(signedIn ? 'start' : 'stop');
      if (signedIn) unawaited(_askBatteryOnce());
    } catch (_) {}
  }

  static Future<void> _askBatteryOnce() async {
    if (_batteryAsked) return;
    _batteryAsked = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('chat.listen.battery.asked') == true) return;
      final exempt = await const MethodChannel(
        'socialsave/session',
      ).invokeMethod<bool>('batteryExempt');
      if (exempt == true) return;
      await prefs.setBool('chat.listen.battery.asked', true);
      await const MethodChannel(
        'socialsave/session',
      ).invokeMethod<void>('requestBatteryExempt');
    } catch (_) {}
  }
}

/// The name this account sees, or the username when no private name is set.
String _alertTitle(String threadId, String fallback) {
  final saved = ChatAlerts.labels[threadId]?.trim() ?? '';
  if (saved.isNotEmpty) return saved;
  final name = fallback.trim();
  return name.isEmpty ? 'New message' : name;
}

/// Listens for messages for the life of the process, including after the
/// window is hidden or the activity is gone.
class ChatAlertWatch {
  ChatAlertWatch._();

  static final instance = ChatAlertWatch._();

  final ChatApi _api = ChatApi();
  Timer? _poll;
  bool _busy = false;
  bool _asked = false;
  String _me = '';

  void ensure() {
    if (_poll != null) return;
    NotificationService.attachChatOpen(_open);
    NotificationService.onReplySent = _keep;
    ChatLive.instance.start();
    unawaited(ChatInboxFilter.ensure());
    ChatLive.instance.events.listen(_onLive);
    _poll = Timer.periodic(
      const Duration(seconds: 12),
      (_) => unawaited(_check()),
    );
    unawaited(_check());
  }

  void _onLive(ChatLiveEvent event) {
    if (event.type == 'call' || event.type.startsWith('call-')) {
      unawaited(ChatCalls.instance.onLive(event));
      return;
    }
    if (event.type == 'removed') {
      if (event.id > 0 && event.threadId.isNotEmpty) {
        unawaited(_drop(event.threadId, event.id));
      }
      return;
    }
    if (event.type != 'message') return;
    final message = event.message;
    if (message == null || message.id <= 0 || event.threadId.isEmpty) return;
    unawaited(_keep(event.threadId, message));
    final prev = ChatAlerts.seen[event.threadId] ?? 0;
    if (message.id <= prev) return;
    ChatAlerts.seen[event.threadId] = message.id;
    unawaited(_alertLive(event.threadId, message));
  }

  Future<void> _drop(String threadId, int id) async {
    if (_me.isEmpty) _me = await ChatSession.username();
    if (_me.isEmpty) return;
    await ChatHistory.hide(username: _me, threadId: threadId, ids: [id]);
  }

  Future<void> _keep(String threadId, ChatMessage message) async {
    if (_me.isEmpty) _me = await ChatSession.username();
    if (_me.isEmpty) return;
    final here = await _here();
    await ChatHistory.remember(
      me: _me,
      threadId: threadId,
      message: message,
      open: here && threadId == ChatAlerts.openThread,
    );
  }

  Future<void> _alertLive(String threadId, ChatMessage message) async {
    if (_me.isEmpty) _me = await ChatSession.username();
    if (_me.isEmpty || chatSameUser(message.name, _me)) return;
    final here = await _here();
    if (here && threadId == ChatAlerts.openThread) return;
    await ChatInboxFilter.ensure();
    if (ChatInboxFilter.isMuted(threadId)) return;
    await ChatPrefs.ensure();
    if (!ChatPrefs.showsNotice(
      threadId: threadId,
      group: threadId.startsWith('g'),
      text: message.text,
      me: _me,
    )) {
      return;
    }
    final title = _alertTitle(threadId, message.name);
    chatAlertNow(
      threadId: threadId,
      title: title,
      body: chatAlertBody(message.text),
      username: message.name,
      photoRev: ChatAlerts.photoRevs[threadId] ?? 0,
    );
  }

  void _open(String payload) {
    final parts = payload.split('|');
    if (parts.length < 3 || parts[0] != 'chat') return;
    final id = parts[1].trim();
    final name = parts.length > 2 ? parts[2].trim() : '';
    final seen = parts.length > 3 ? parts.sublist(3).join('|').trim() : '';
    if (id.isEmpty) return;
    if (Plat.isWindows) unawaited(DesktopTray.show());
    appRouter.push(
      '/chat/$id',
      extra: ChatThreadTarget(username: name, name: seen),
    );
  }

  Future<bool> _here() {
    return _androidScreenOn().then((screenOn) {
      return chatUserIsHere(
        life: WidgetsBinding.instance.lifecycleState,
        screenOn: screenOn,
      );
    });
  }

  Future<void> _check() async {
    if (_busy) return;
    if (!chatInboxCheckRuns(WidgetsBinding.instance.lifecycleState)) return;
    await ChatPrefs.ensure();
    final fresh = ChatAlerts.lastInbox;
    final gap = ChatPrefs.dataSaver
        ? const Duration(seconds: 30)
        : const Duration(seconds: 10);
    if (fresh != null && DateTime.now().difference(fresh) < gap) {
      unawaited(ChatPresence.sync());
      return;
    }
    final token = await ChatSession.token();
    if (token == null) {
      ChatAlerts.reset();
      return;
    }
    ChatLive.instance.start();
    unawaited(ChatPresence.sync());
    _busy = true;
    try {
      if (!_asked) {
        _asked = true;
        unawaited(NotificationService().requestPermission());
      }
      final items = await _api.threads();
      _me = await ChatSession.username();
      if (_me.isNotEmpty) {
        unawaited(ChatHistory.archiveInbox(_api, _me, items));
      }
      await ChatInboxFilter.ensure();
      final here = await _here();
      ChatAlerts.observe(
        items,
        me: _me,
        notify: true,
        holdOpen: here,
        alert: (item, body) {
          final group = item.group || item.id.startsWith('g');
          if (!ChatPrefs.showsNotice(
            threadId: item.id,
            group: group,
            text: body,
            me: _me,
          )) {
            return;
          }
          final title = _alertTitle(item.id, item.label);
          chatAlertNow(
            threadId: item.id,
            title: title,
            body: body,
            username: item.username,
            photoRev: item.photoRev,
          );
        },
      );
      keepChatFacesForNotifications();
      if (!ChatPrefs.dataSaver) {
        for (final item in items) {
          if (item.username.isEmpty || item.photoRev <= 0) continue;
          unawaited(ChatPhotos.fetch(item.username, item.photoRev));
        }
      }
    } catch (_) {
      // The next pass tries again. A quiet miss is better than a banner on Home.
    } finally {
      _busy = false;
    }
  }
}

/// Stays mounted on every screen, including a conversation.
class ChatAlertHost extends StatefulWidget {
  const ChatAlertHost({super.key});

  @override
  State<ChatAlertHost> createState() => _ChatAlertHostState();
}

class _ChatAlertHostState extends State<ChatAlertHost> {
  @override
  void initState() {
    super.initState();
    ChatAlertWatch.instance.ensure();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Usernames match without case or a leading @.
bool chatSameUser(String a, String b) {
  String n(String s) => s.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
  return n(a).isNotEmpty && n(a) == n(b);
}
