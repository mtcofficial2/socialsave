import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
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
      _pushSeen();
      return;
    }
    for (final item in items) {
      if (item.id.isEmpty) continue;
      final prev = seen[item.id] ?? 0;
      final grew = item.lastId > prev && item.lastId > 0;
      seen[item.id] = item.lastId > prev ? item.lastId : prev;
      if (!notify || !grew || alert == null) continue;
      if (item.lastFrom.isEmpty) continue;
      // The open chat stays quiet, including a message you just sent there.
      // On the phone, a send from your other device still notifies once that
      // chat is not the one on screen. Windows stays quiet for your own sends.
      final own = chatSameUser(item.lastFrom, me);
      if (own && !Plat.isAndroid) continue;
      if (holdOpen && item.id == openThread) continue;
      if (ChatInboxFilter.isMuted(item.id)) continue;
      alert(item, chatAlertBody(item.lastText));
    }
    _pushSeen();
  }

  static void _pushSeen() {
    if (!Plat.isAndroid || seen.isEmpty) return;
    unawaited(
      const MethodChannel('socialsave/chat_listen').invokeMethod<void>('seen', {
        'ids': <String, int>{
          for (final entry in seen.entries) entry.key: entry.value,
        },
      }),
    );
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
    if (signedIn) {
      try {
        await const MethodChannel('socialsave/chat_listen').invokeMethod<void>(
          'creds',
          {
            'api': chatApiBaseUrl(),
            'token': token,
            'me': await ChatSession.username(),
          },
        );
      } catch (_) {}
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
  Timer? _calls;
  StreamSubscription<List<ConnectivityResult>>? _net;
  bool _busy = false;
  bool _again = false;
  bool _asked = false;
  bool _offline = false;
  bool _socketDown = true;
  String _me = '';

  void ensure() {
    _listenForWake();
    if (_poll != null || _calls != null) return;
    NotificationService.attachChatOpen(_open);
    NotificationService.attachCall(_onCall);
    NotificationService.onCallOpen = () {
      if (Plat.isWindows) unawaited(DesktopTray.show());
    };
    NotificationService.onReplySent = _keep;
    ChatLive.instance.start();
    ChatLive.instance.connected.addListener(_onSocket);
    unawaited(ChatInboxFilter.ensure());
    ChatLive.instance.events.listen(_onLive);
    _poll = Timer.periodic(
      const Duration(seconds: 12),
      (_) => unawaited(_check()),
    );
    if (callsOnThisDevice(windows: Plat.isWindows)) {
      _calls = Timer.periodic(
        const Duration(seconds: 4),
        (_) => unawaited(ChatCalls.instance.syncIncoming()),
      );
      unawaited(ChatCalls.instance.syncIncoming());
    }
    _net = Connectivity().onConnectivityChanged.listen((results) {
      final offline = results.length == 1 && results.contains(ConnectivityResult.none);
      if (offline) {
        _offline = true;
        return;
      }
      if (!_offline) return;
      _offline = false;
      unawaited(_check(force: true));
      if (callsOnThisDevice(windows: Plat.isWindows)) {
        unawaited(ChatCalls.instance.syncIncoming());
      }
    });
    unawaited(_check());
  }

  void _onSocket() {
    if (!ChatLive.instance.connected.value) {
      _socketDown = true;
      return;
    }
    if (!_socketDown) return;
    _socketDown = false;
    unawaited(_check(force: true));
  }

  void _onCall(String payload) {
    final parts = payload.split('|');
    if (parts.length < 2) return;
    final id = parts[1].trim();
    if (id.isEmpty) return;
    if (parts[0] == 'answer') {
      unawaited(ChatCalls.instance.acceptNotice(id));
      return;
    }
    if (parts[0] == 'decline') {
      unawaited(ChatCalls.instance.noticeDeclined(id));
      return;
    }
    if (parts[0] == 'open') unawaited(ChatCalls.instance.syncIncoming());
  }

  bool _wakeListening = false;

  void _listenForWake() {
    if (_wakeListening || !Plat.isAndroid) return;
    _wakeListening = true;
    const MethodChannel('socialsave/chat_listen').setMethodCallHandler((call) async {
      if (call.method != 'check') return null;
      // Do not await. _check calls back into this channel, and waiting here
      // would stall the platform thread.
      unawaited(_check(force: true));
      unawaited(Future<void>.delayed(const Duration(seconds: 3), () => _check(force: true)));
      unawaited(Future<void>.delayed(const Duration(seconds: 8), () => _check(force: true)));
      return true;
    });
  }

  Future<void> _beat() async {
    if (!Plat.isAndroid) return;
    try {
      await const MethodChannel('socialsave/chat_listen').invokeMethod<void>('beat');
    } catch (_) {}
  }

  Future<void> _rest() async {
    if (!Plat.isAndroid) return;
    try {
      await const MethodChannel('socialsave/chat_listen').invokeMethod<void>('rest');
    } catch (_) {}
  }

  void _onLive(ChatLiveEvent event) {
    if (event.type == 'call' || event.type.startsWith('call-')) {
      if (callsOnThisDevice(windows: Plat.isWindows)) {
        unawaited(ChatCalls.instance.onLive(event));
      }
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
    ChatAlerts._pushSeen();
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
    if (_me.isEmpty) return;
    final here = await _here();
    final own = chatSameUser(message.name, _me);
    if (own && !Plat.isAndroid) return;
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
    final body = chatAlertBody(message.text);
    chatAlertNow(
      threadId: threadId,
      title: title,
      body: own ? _fromYou(body) : body,
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

  Future<void> _check({bool force = false}) async {
    if (_busy) {
      if (force) _again = true;
      return;
    }
    _busy = true;
    var fetched = false;
    try {
      if (!chatInboxCheckRuns(WidgetsBinding.instance.lifecycleState)) return;
      await ChatPrefs.ensure();
      final fresh = ChatAlerts.lastInbox;
      final gap = ChatPrefs.dataSaver
          ? const Duration(seconds: 30)
          : const Duration(seconds: 10);
      if (!force && fresh != null && DateTime.now().difference(fresh) < gap) {
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
      if (!_asked) {
        _asked = true;
        unawaited(NotificationService().requestPermission());
      }
      await _beat();
      fetched = true;
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
          final own = chatSameUser(item.lastFrom, _me);
          chatAlertNow(
            threadId: item.id,
            title: title,
            body: own ? _fromYou(body) : body,
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
      // A beat with no inbox would hide the native listener for 20 seconds.
      if (fetched) unawaited(_rest());
    } finally {
      _busy = false;
      if (_again) {
        _again = false;
        unawaited(_check(force: true));
      }
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

/// A call this phone placed. It stays on top of the chat and does not cover it.
class ChatOutgoingBar extends StatelessWidget {
  const ChatOutgoingBar({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: ChatCalls.revision,
      builder: (context, _, _) {
        final call = ChatCalls.instance;
        final live = call.outgoing && call.exitKind.isEmpty && call.status == 'ringing';
        if (!live) return const SizedBox.shrink();
        final name = call.peerName.trim().isEmpty ? 'Audio call' : call.peerName.trim();
        const line = 'Calling…';
        return SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Material(
              color: const Color(0xFF1F2C34),
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                child: Row(
                  children: [
                    const Icon(Icons.call_rounded, color: Color(0xFF53BDEB), size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                          ),
                          Text(line, style: const TextStyle(color: Color(0xFFAEBAC1), fontSize: 13)),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () => unawaited(call.hangUp()),
                      child: const Text(
                        'End',
                        style: TextStyle(color: Color(0xFFFF8A80), fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A message this account sent from another device.
String _fromYou(String body) {
  if (body.startsWith('You: ')) return body;
  return 'You: $body';
}

/// Usernames match without case or a leading @.
bool chatSameUser(String a, String b) {
  String n(String s) => s.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
  return n(a).isNotEmpty && n(a) == n(b);
}
