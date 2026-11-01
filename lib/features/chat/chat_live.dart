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
  static final Map<String, DateTime> _recordingUntil = {};

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
  void Function(String id)? resendPhoto;
  DateTime? _typedAt;
  String _typingThread = '';
  bool _typingOn = false;
  DateTime? _recordedAt;
  String _recordingThread = '';
  bool _recordingOn = false;
  final Map<String, DateTime> _photoAsk = {};

  Stream<ChatLiveEvent> get events => _events.stream;

  static bool isTyping(String id) {
    final until = _typingUntil[id];
    return until != null && until.isAfter(DateTime.now());
  }

  static bool isRecording(String id) {
    final until = _recordingUntil[id];
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
    if (_typingOn && _typingThread.isNotEmpty) {
      _typedAt = null;
      sendText(
        jsonEncode({
          'type': 'typing',
          'thread': _typingThread,
          'on': true,
        }),
      );
      _typedAt = DateTime.now();
    }
    if (_recordingOn && _recordingThread.isNotEmpty) {
      _recordedAt = null;
      sendText(
        jsonEncode({
          'type': 'recording',
          'thread': _recordingThread,
          'on': true,
        }),
      );
      _recordedAt = DateTime.now();
    }
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
    _typingThread = threadId;
    _typingOn = on;
    if (_sendText == null) return;
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

  void recording(String threadId, {required bool on}) {
    if (threadId.isEmpty) return;
    _recordingThread = threadId;
    _recordingOn = on;
    if (on) {
      _typingOn = false;
      _typedAt = null;
    }
    if (_sendText == null) return;
    if (!on) {
      _recordedAt = null;
      sendText(
        jsonEncode({'type': 'recording', 'thread': threadId, 'on': false}),
      );
      return;
    }
    final now = DateTime.now();
    if (_recordedAt != null &&
        now.difference(_recordedAt!) < const Duration(seconds: 2)) {
      return;
    }
    _recordedAt = now;
    sendText(
      jsonEncode({'type': 'recording', 'thread': threadId, 'on': true}),
    );
  }

  /// Asks the sender to pass this picture again. The server does not keep it.
  void wantPhoto(String threadId, String id) {
    if (threadId.isEmpty || id.isEmpty || _sendText == null) return;
    final now = DateTime.now();
    final prev = _photoAsk[id];
    if (prev != null && now.difference(prev) < const Duration(seconds: 4)) {
      return;
    }
    _photoAsk[id] = now;
    sendText(
      jsonEncode({'type': 'photo-need', 'thread': threadId, 'id': id}),
    );
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
    final on = data['on'] == true || data['online'] == true;
    final rawId = data['id'];
    final id = rawId is num ? rawId.toInt() : 0;
    final at = (data['lastSeen'] as num?)?.toInt() ?? 0;
    final photoId = type == 'photo-ok' || type == 'photo-wait'
        ? ((data['id'] as String?)?.trim() ?? '')
        : '';
    ChatMessage? message;
    final rawMessage = data['message'];
    if (rawMessage is Map) {
      message = ChatMessage.fromJson(Map<String, dynamic>.from(rawMessage));
    }
    if (type == 'typing' || type == 'recording') {
      final book = type == 'recording' ? _recordingUntil : _typingUntil;
      if (on) {
        book[threadId] = DateTime.now().add(const Duration(seconds: 4));
        if (type == 'recording') _typingUntil.remove(threadId);
      } else {
        book.remove(threadId);
      }
      revision.value++;
    }
    if (type == 'photo-ok' && photoId.isNotEmpty) {
      _photoAsk.remove(photoId);
      deliveredPhoto?.call(photoId);
    }
    if (type == 'photo-wait' && photoId.isNotEmpty) resendPhoto?.call(photoId);
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
