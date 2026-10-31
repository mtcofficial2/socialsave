import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_socket_stub.dart'
    if (dart.library.io) 'package:social_save/features/chat/chat_socket_io.dart';

class ChatLiveEvent {
  const ChatLiveEvent({
    required this.type,
    this.threadId = '',
    this.message,
    this.from = '',
    this.on = false,
    this.id = 0,
    this.at = 0,
    this.photoId = '',
  });

  final String type;
  final String threadId;
  final ChatMessage? message;
  final String from;
  final bool on;
  final int id;
  final int at;
  final String photoId;
}

/// One live connection for messages, typing, and pictures.
class ChatLive {
  ChatLive._();

  static final instance = ChatLive._();
  static final revision = ValueNotifier<int>(0);
  static final Map<String, DateTime> _typingUntil = {};

  final connected = ValueNotifier<bool>(false);
  final _events = StreamController<ChatLiveEvent>.broadcast();

  bool _started = false;
  bool stopped = false;
  int epoch = 0;
  void Function(String text)? _sendText;
  void Function(Uint8List bytes)? _sendBinary;
  void Function()? _close;
  void Function(String id)? deliveredPhoto;
  void Function()? resendPhotos;
  DateTime? _typedAt;

  Stream<ChatLiveEvent> get events => _events.stream;

  static bool isTyping(String id) {
    final until = _typingUntil[id];
    return until != null && until.isAfter(DateTime.now());
  }

  void start() {
    if (_started) return;
    _started = true;
    stopped = false;
    final ticket = ++epoch;
    unawaited(runChatSocket(this, ticket));
  }

  void stop() {
    stopped = true;
    _started = false;
    epoch++;
    connected.value = false;
    _close?.call();
    _sendText = null;
    _sendBinary = null;
    _close = null;
  }

  void attach({
    required void Function(String text) text,
    required void Function(Uint8List bytes) binary,
    required void Function() close,
  }) {
    _sendText = text;
    _sendBinary = binary;
    _close = close;
    connected.value = true;
  }

  void detach() {
    _sendText = null;
    _sendBinary = null;
    _close = null;
    connected.value = false;
  }

  void sendText(String text) => _sendText?.call(text);

  void sendBinary(Uint8List bytes) => _sendBinary?.call(bytes);

  void typing(String threadId, {required bool on}) {
    if (threadId.isEmpty) return;
    if (!on) {
      _typedAt = null;
      sendText(jsonEncode({'type': 'typing', 'thread': threadId, 'on': false}));
      return;
    }
    final now = DateTime.now();
    if (_typedAt != null &&
        now.difference(_typedAt!) < const Duration(seconds: 2)) {
      return;
    }
    _typedAt = now;
    sendText(jsonEncode({'type': 'typing', 'thread': threadId, 'on': true}));
  }

  void onText(String raw) {
    Object? data;
    try {
      data = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (data is! Map) return;
    final type = (data['type'] as String?)?.trim() ?? '';
    final threadId = (data['thread'] as String?)?.trim() ?? '';
    final named = data['from'] ?? data['username'];
    final from = named is String ? named.trim() : '';
    final on = data['on'] == true;
    final id = (data['id'] as num?)?.toInt() ?? 0;
    final at = (data['lastSeen'] as num?)?.toInt() ?? 0;
    final photoId = type == 'photo-ok' || type == 'photo-wait'
        ? ((data['id'] as String?)?.trim() ?? '')
        : '';
    ChatMessage? message;
    final rawMessage = data['message'];
    if (rawMessage is Map) {
      message = ChatMessage.fromJson(Map<String, dynamic>.from(rawMessage));
    }
    if (type == 'typing') {
      if (on) {
        _typingUntil[threadId] = DateTime.now().add(const Duration(seconds: 4));
      } else {
        _typingUntil.remove(threadId);
      }
      revision.value++;
    }
    if (type == 'photo-ok' && photoId.isNotEmpty) deliveredPhoto?.call(photoId);
    if (type == 'presence' && on) resendPhotos?.call();
    if (_events.isClosed) return;
    _events.add(
      ChatLiveEvent(
        type: type,
        threadId: threadId,
        message: message,
        from: from,
        on: on,
        id: id,
        at: at,
        photoId: photoId,
      ),
    );
  }
}
