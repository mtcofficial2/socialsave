import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:social_save/core/notifications/notification_service.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/features/chat/chat_history.dart';
import 'package:social_save/features/chat/chat_live.dart';
import 'package:social_save/features/chat/chat_ui.dart';
import 'package:social_save/shared/routing/app_router.dart';

/// A sound plus a notification. Android's system "alert" sound does nothing,
/// so an open app plays the phone's notification tone itself and keeps the
/// banner quiet. In the background the notification channel sounds. Windows
/// only has a system beep, including when the window is in the background.
void chatAlertNow({
  required String threadId,
  required String title,
  required String body,
}) {
  final life = WidgetsBinding.instance.lifecycleState;
  final resumed = life == null || life == AppLifecycleState.resumed;
  final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  final windows = !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  if (android && resumed) {
    unawaited(_playPhoneTone());
  }
  if (windows) {
    unawaited(SystemSound.play(SystemSoundType.alert));
  }
  unawaited(
    NotificationService().showChat(
      threadId: threadId,
      title: title,
      body: body,
      sound: !resumed,
    ),
  );
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

  static void reset() {
    lastInbox = null;
    seeded = false;
    seen.clear();
    openThread = '';
    ChatLive.instance.stop();
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
    void Function(ChatThreadSummary item, String body)? alert,
  }) {
    lastInbox = DateTime.now();
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
      if (item.lastFrom.isEmpty || item.lastFrom == me) continue;
      if (item.id == openThread) continue;
      if (ChatInboxFilter.isMuted(item.id)) continue;
      alert(item, chatAlertBody(item.lastText));
    }
  }
}

/// Stays mounted on every screen, including a conversation.
class ChatAlertHost extends StatefulWidget {
  const ChatAlertHost({super.key});

  @override
  State<ChatAlertHost> createState() => _ChatAlertHostState();
}

class _ChatAlertHostState extends State<ChatAlertHost>
    with WidgetsBindingObserver {
  final ChatApi _api = ChatApi();
  Timer? _poll;
  StreamSubscription<ChatLiveEvent>? _live;
  bool _busy = false;
  bool _asked = false;
  String _me = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationService.onChatOpen = _open;
    ChatLive.instance.start();
    unawaited(ChatInboxFilter.ensure());
    _live = ChatLive.instance.events.listen(_onLive);
    _poll = Timer.periodic(
      const Duration(seconds: 12),
      (_) => unawaited(_check()),
    );
    unawaited(_check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _live?.cancel();
    if (NotificationService.onChatOpen == _open) {
      NotificationService.onChatOpen = null;
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _poll?.cancel();
    _poll = null;
    if (state == AppLifecycleState.resumed) {
      _poll = Timer.periodic(
        const Duration(seconds: 12),
        (_) => unawaited(_check()),
      );
      unawaited(_check());
    }
  }

  void _onLive(ChatLiveEvent event) {
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
    await ChatHistory.remember(
      me: _me,
      threadId: threadId,
      message: message,
      open: threadId == ChatAlerts.openThread,
    );
  }

  Future<void> _alertLive(String threadId, ChatMessage message) async {
    if (_me.isEmpty) _me = await ChatSession.username();
    if (!mounted) return;
    if (_me.isNotEmpty && message.name == _me) return;
    if (threadId == ChatAlerts.openThread) return;
    await ChatInboxFilter.ensure();
    if (ChatInboxFilter.isMuted(threadId)) return;
    final title = message.name.isEmpty ? 'New message' : message.name;
    chatAlertNow(
      threadId: threadId,
      title: title,
      body: chatAlertBody(message.text),
    );
  }

  void _open(String payload) {
    final parts = payload.split('|');
    if (parts.length < 3 || parts[0] != 'chat' || !mounted) return;
    final id = parts[1].trim();
    final name = parts.sublist(2).join('|').trim();
    if (id.isEmpty) return;
    appRouter.push('/chat/$id', extra: name);
  }

  Future<void> _check() async {
    if (_busy || !mounted) return;
    final life = WidgetsBinding.instance.lifecycleState;
    if (life != null && life != AppLifecycleState.resumed) return;
    final fresh = ChatAlerts.lastInbox;
    if (fresh != null &&
        DateTime.now().difference(fresh) < const Duration(seconds: 10)) {
      return;
    }
    final token = await ChatSession.token();
    if (!mounted) return;
    if (token == null) {
      ChatAlerts.reset();
      return;
    }
    ChatLive.instance.start();
    _busy = true;
    try {
      if (!_asked) {
        _asked = true;
        unawaited(NotificationService().requestPermission());
      }
      final items = await _api.threads();
      if (!mounted) return;
      _me = await ChatSession.username();
      if (_me.isNotEmpty) {
        unawaited(ChatHistory.archiveInbox(_api, _me, items));
      }
      await ChatInboxFilter.ensure();
      ChatAlerts.observe(
        items,
        me: _me,
        notify: true,
        alert: (item, body) {
          final title = item.username.isEmpty ? 'New message' : item.username;
          chatAlertNow(threadId: item.id, title: title, body: body);
        },
      );
    } catch (_) {
      // The next pass tries again. A quiet miss is better than a banner on Home.
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
