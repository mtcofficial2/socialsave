import 'dart:async';

import 'package:flutter/material.dart';
import 'package:social_save/core/notifications/notification_service.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/shared/routing/app_router.dart';

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
        seen[item.id] = item.lastId;
      }
      seeded = true;
      return;
    }
    for (final item in items) {
      if (item.id.isEmpty) continue;
      final prev = seen[item.id] ?? 0;
      final grew = item.lastId > prev && item.lastId > 0;
      seen[item.id] = item.lastId;
      if (!notify || !grew || alert == null) continue;
      if (item.lastFrom.isEmpty || item.lastFrom == me) continue;
      if (item.id == openThread) continue;
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

class _ChatAlertHostState extends State<ChatAlertHost> with WidgetsBindingObserver {
  final ChatApi _api = ChatApi();
  Timer? _poll;
  bool _busy = false;
  bool _asked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationService.onChatOpen = _open;
    _poll = Timer.periodic(const Duration(seconds: 12), (_) => unawaited(_check()));
    unawaited(_check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    if (NotificationService.onChatOpen == _open) NotificationService.onChatOpen = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _poll?.cancel();
    _poll = null;
    if (state == AppLifecycleState.resumed) {
      _poll = Timer.periodic(const Duration(seconds: 12), (_) => unawaited(_check()));
      unawaited(_check());
    }
  }

  void _open(String payload) {
    final parts = payload.split('|');
    if (parts.length < 3 || parts[0] != 'chat' || !mounted) return;
    final id = parts[1].trim();
    final name = parts.sublist(2).join('|').trim();
    if (id.isEmpty) return;
    appRouter.push('/chat/$id', extra: name);
  }

  bool _listIsOpen() {
    final path = appRouter.routeInformationProvider.value.uri.path;
    return path == '/chat' || path == '/chat/';
  }

  Future<void> _check() async {
    if (_busy || !mounted) return;
    final life = WidgetsBinding.instance.lifecycleState;
    if (life != null && life != AppLifecycleState.resumed) return;
    final fresh = ChatAlerts.lastInbox;
    if (fresh != null && DateTime.now().difference(fresh) < const Duration(seconds: 10)) return;
    final token = await ChatSession.token();
    if (!mounted) return;
    if (token == null) {
      ChatAlerts.reset();
      return;
    }
    _busy = true;
    try {
      if (!_asked) {
        _asked = true;
        unawaited(NotificationService().requestPermission());
      }
      final items = await _api.threads();
      if (!mounted) return;
      final me = await ChatSession.username();
      final listOpen = _listIsOpen();
      ChatAlerts.observe(
        items,
        me: me,
        notify: !listOpen,
        alert: (item, body) {
          final title = item.username.isEmpty ? 'New message' : item.username;
          unawaited(NotificationService().showChat(threadId: item.id, title: title, body: body));
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
