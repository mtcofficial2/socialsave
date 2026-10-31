import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/config/build_flags.dart';
import 'package:social_save/core/config/env_config.dart';

const chatTokenKey = 'chat.token.v1';
const chatUsernameKey = 'chat.username.v1';
const chatContactKey = 'chat.contact.v1';
const chatReadKey = 'chat.read.v1';

/// Last message id this device has opened, per conversation.
class ChatReads {
  static Future<Map<String, int>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(chatReadKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is num) entry.key as String: (entry.value as num).toInt(),
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> mark(String threadId, int messageId) async {
    if (threadId.isEmpty || messageId <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    final current = await load();
    if ((current[threadId] ?? 0) >= messageId) return;
    current[threadId] = messageId;
    await prefs.setString(chatReadKey, jsonEncode(current));
  }
}

/// This device's chat account. The token is the login. It is not a code.
class ChatSession {
  static Future<String?> token() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(chatTokenKey)?.trim() ?? '';
    return value.isEmpty ? null : value;
  }

  static Future<String> username() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(chatUsernameKey)?.trim() ?? '';
  }

  static Future<String> contact() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(chatContactKey)?.trim() ?? '';
  }

  static Future<void> save({
    required String token,
    required String username,
    required String contact,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(chatTokenKey, token);
    await prefs.setString(chatUsernameKey, username);
    await prefs.setString(chatContactKey, contact);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(chatTokenKey);
    await prefs.remove(chatUsernameKey);
    await prefs.remove(chatContactKey);
  }
}

class ChatUser {
  const ChatUser({
    required this.id,
    required this.username,
    required this.phone,
    required this.email,
    this.photoRev = 0,
  });

  final String id;
  final String username;
  final String phone;
  final String email;
  final int photoRev;

  ChatUser copyWith({int? photoRev}) {
    return ChatUser(
      id: id,
      username: username,
      phone: phone,
      email: email,
      photoRev: photoRev ?? this.photoRev,
    );
  }

  String get contact {
    if (email.isNotEmpty && phone.isNotEmpty) return '$phone · $email';
    return email.isNotEmpty ? email : phone;
  }

  factory ChatUser.fromJson(Map<String, dynamic> json) {
    return ChatUser(
      id: (json['id'] as String?)?.trim() ?? '',
      username: (json['username'] as String?)?.trim() ?? '',
      phone: (json['phone'] as String?)?.trim() ?? '',
      email: (json['email'] as String?)?.trim() ?? '',
      photoRev: (json['photoRev'] as num?)?.toInt() ?? 0,
    );
  }
}

class ChatRegistration {
  const ChatRegistration({required this.token, required this.user});

  final String token;
  final ChatUser user;
}

class ChatThreadSummary {
  const ChatThreadSummary({
    required this.id,
    required this.username,
    this.lastText = '',
    this.lastAt,
    this.lastId = 0,
    this.lastFrom = '',
    this.lastStatus = '',
    this.unread = 0,
    this.lastSeen,
    this.online = false,
    this.photoRev = 0,
  });

  final String id;
  final String username;
  final String lastText;
  final DateTime? lastAt;
  final int lastId;
  final String lastFrom;
  final String lastStatus;
  final int unread;
  final DateTime? lastSeen;
  final bool online;
  final int photoRev;

  factory ChatThreadSummary.fromJson(Map<String, dynamic> json) {
    final at = (json['lastAt'] as num?)?.toInt() ?? 0;
    final seen = (json['lastSeen'] as num?)?.toInt() ?? 0;
    return ChatThreadSummary(
      id: (json['id'] as String?)?.trim() ?? '',
      username: (json['username'] as String?)?.trim() ?? '',
      lastText: (json['lastText'] as String?)?.trim() ?? '',
      lastAt: at > 0 ? DateTime.fromMillisecondsSinceEpoch(at) : null,
      lastId: (json['lastId'] as num?)?.toInt() ?? 0,
      lastFrom: (json['lastFrom'] as String?)?.trim() ?? '',
      lastStatus: (json['lastStatus'] as String?)?.trim() ?? '',
      unread: (json['unread'] as num?)?.toInt() ?? 0,
      lastSeen: seen > 0 ? DateTime.fromMillisecondsSinceEpoch(seen) : null,
      online: json['online'] == true && seen > 0,
      photoRev: (json['photoRev'] as num?)?.toInt() ?? 0,
    );
  }
}

/// One direct message. [name] is the sender's username.
class ChatSync {
  const ChatSync({
    required this.messages,
    this.peerDelivered = 0,
    this.peerRead = 0,
    this.peerLastSeen,
    this.peerOnline = false,
    this.peerPhotoRev = 0,
  });

  final List<ChatMessage> messages;
  final int peerDelivered;
  final int peerRead;
  final DateTime? peerLastSeen;
  final bool peerOnline;
  final int peerPhotoRev;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.from,
    required this.name,
    required this.text,
    required this.links,
    required this.at,
    this.status = '',
    this.voice = '',
    this.voiceMs = 0,
    this.voiceType = '',
    this.reply = 0,
    this.replyName = '',
    this.replyText = '',
    this.photo = '',
    this.photoType = '',
    this.localBytes,
    this.pendingKind = '',
  });

  final int id;
  final String from;
  final String name;
  final String text;
  final List<String> links;
  final DateTime at;
  final String status;
  final String voice;
  final int voiceMs;
  final String voiceType;
  final int reply;
  final String replyName;
  final String replyText;
  final String photo;
  final String photoType;
  final Uint8List? localBytes;
  final String pendingKind;

  bool get isVoice => voice.isNotEmpty || pendingKind == 'voice';
  bool get isPhoto => photo.isNotEmpty || pendingKind == 'photo';

  ChatMessage copyWith({String? status}) {
    return ChatMessage(
      id: id,
      from: from,
      name: name,
      text: text,
      links: links,
      at: at,
      status: status ?? this.status,
      voice: voice,
      voiceMs: voiceMs,
      voiceType: voiceType,
      reply: reply,
      replyName: replyName,
      replyText: replyText,
      photo: photo,
      photoType: photoType,
      localBytes: localBytes,
      pendingKind: pendingKind,
    );
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final links = json['links'];
    return ChatMessage(
      id: (json['id'] as num?)?.toInt() ?? 0,
      from: (json['from'] as String?)?.trim() ?? '',
      name: (json['name'] as String?)?.trim().isNotEmpty == true ? (json['name'] as String).trim() : 'Someone',
      text: (json['text'] as String?)?.trim() ?? '',
      links: links is List ? links.whereType<String>().where((item) => item.startsWith('http')).toList() : const [],
      at: DateTime.fromMillisecondsSinceEpoch((json['at'] as num?)?.toInt() ?? 0),
      status: (json['status'] as String?)?.trim() ?? '',
      voice: (json['voice'] as String?)?.trim() ?? '',
      voiceMs: (json['voiceMs'] as num?)?.toInt() ?? 0,
      voiceType: (json['voiceType'] as String?)?.trim() ?? '',
      reply: (json['reply'] as num?)?.toInt() ?? 0,
      replyName: (json['replyName'] as String?)?.trim() ?? '',
      replyText: (json['replyText'] as String?)?.trim() ?? '',
      photo: (json['photo'] as String?)?.trim() ?? '',
      photoType: (json['photoType'] as String?)?.trim() ?? '',
    );
  }
}

class ChatSignedOut implements Exception {
  const ChatSignedOut();
}

/// Chat stays on the hosted API. A Windows build keeps downloads on this PC.
String chatApiBaseUrl() {
  if (!kLocalEngine) return EnvConfig.apiBaseUrl;
  const defined = String.fromEnvironment('API_BASE_URL');
  final trimmed = defined.trim();
  if (trimmed.isNotEmpty) {
    return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }
  return 'https://socialsave-api-p2tm.onrender.com';
}

class ChatApi {
  ChatApi({Dio? dio, String? baseUrl})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl ?? chatApiBaseUrl(),
                connectTimeout: const Duration(seconds: 20),
                receiveTimeout: const Duration(seconds: 70),
                sendTimeout: const Duration(seconds: 20),
                headers: {
                  'Accept': 'application/json',
                  'Content-Type': 'application/json',
                  if (EnvConfig.hasApiKey) 'Authorization': 'Bearer ${EnvConfig.apiKey}',
                },
              ),
            );

  final Dio _dio;

  Future<ChatRegistration> register({
    String phone = '',
    String email = '',
    required String username,
  }) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/register',
      data: {
        'username': username,
        if (phone.trim().isNotEmpty) 'phone': phone.trim(),
        if (email.trim().isNotEmpty) 'email': email.trim(),
      },
    );
    final body = _object(response);
    final token = (body['token'] as String?)?.trim() ?? '';
    final user = body['user'];
    if (token.isEmpty || user is! Map) {
      throw DioException(
        requestOptions: response.requestOptions,
        message: 'The chat server did not create the account.',
      );
    }
    return ChatRegistration(token: token, user: ChatUser.fromJson(Map<String, dynamic>.from(user)));
  }

  Future<ChatUser> me() async {
    final response = await _dio.get<dynamic>('/api/v1/chat/me', options: await _auth());
    final user = _object(response)['user'];
    if (user is! Map) {
      throw DioException(
        requestOptions: response.requestOptions,
        message: 'The chat server did not return this account.',
      );
    }
    return ChatUser.fromJson(Map<String, dynamic>.from(user));
  }

  Future<List<ChatThreadSummary>> threads() async {
    final response = await _dio.get<dynamic>('/api/v1/chat/threads', options: await _auth());
    final items = _object(response)['threads'];
    if (items is! List) return const [];
    return [
      for (final item in items)
        if (item is Map) ChatThreadSummary.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  Future<ChatThreadSummary> openThread(String username) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/threads',
      data: {'username': username},
      options: await _auth(),
    );
    final body = _object(response);
    final id = (body['id'] as String?)?.trim() ?? '';
    final name = (body['username'] as String?)?.trim() ?? username.trim();
    if (id.isEmpty) {
      throw DioException(
        requestOptions: response.requestOptions,
        message: 'The chat server did not open that conversation.',
      );
    }
    return ChatThreadSummary(id: id, username: name, lastText: '', lastAt: null);
  }

  Future<ChatSync> messages(String id, int after) async {
    final response = await _dio.get<dynamic>(
      '/api/v1/chat/threads/$id',
      queryParameters: {'after': after},
      options: await _auth(),
    );
    final body = _object(response);
    final items = body['messages'];
    final peer = body['peer'];
    var delivered = 0;
    var read = 0;
    DateTime? seen;
    var online = false;
    var photoRev = 0;
    if (peer is Map) {
      delivered = (peer['delivered'] as num?)?.toInt() ?? 0;
      read = (peer['read'] as num?)?.toInt() ?? 0;
      final at = (peer['lastSeen'] as num?)?.toInt() ?? 0;
      if (at > 0) seen = DateTime.fromMillisecondsSinceEpoch(at);
      online = peer['online'] == true && seen != null;
      photoRev = (peer['photoRev'] as num?)?.toInt() ?? 0;
    }
    return ChatSync(
      peerDelivered: delivered,
      peerRead: read,
      peerLastSeen: seen,
      peerOnline: online,
      peerPhotoRev: photoRev,
      messages: [
        if (items is List)
          for (final item in items)
            if (item is Map) ChatMessage.fromJson(Map<String, dynamic>.from(item)),
      ],
    );
  }

  Future<void> markRead(String id, int messageId) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/threads/$id/read',
      data: {'id': messageId},
      options: await _auth(),
    );
  }

  Future<ChatMessage> send(String id, String text, {int reply = 0}) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/threads/$id',
      data: {
        'text': text,
        if (reply > 0) 'reply': reply,
      },
      options: await _auth(),
    );
    final message = _object(response)['message'];
    if (message is! Map) {
      throw DioException(
        requestOptions: response.requestOptions,
        message: 'The chat server did not return the message.',
      );
    }
    return ChatMessage.fromJson(Map<String, dynamic>.from(message));
  }

  Future<int> setPhoto(Uint8List bytes) async {
    final auth = await _auth();
    final headers = Map<String, dynamic>.from(auth.headers ?? {});
    headers['Content-Type'] = 'application/octet-stream';
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/photo',
      data: bytes,
      options: auth.copyWith(
        headers: headers,
        contentType: 'application/octet-stream',
        sendTimeout: const Duration(seconds: 40),
      ),
    );
    final rev = (_object(response)['photoRev'] as num?)?.toInt() ?? 0;
    if (rev <= 0) {
      throw DioException(requestOptions: response.requestOptions, message: 'That photo could not be saved.');
    }
    return rev;
  }

  Future<Uint8List?> photo(String username) async {
    final name = username.trim();
    if (name.isEmpty) return null;
    try {
      final auth = await _auth();
      final response = await _dio.get<dynamic>(
        '/api/v1/chat/photo',
        queryParameters: {'username': name},
        options: auth.copyWith(responseType: ResponseType.bytes),
      );
      final data = response.data;
      if (data is Uint8List && data.isNotEmpty) return data;
      if (data is List<int> && data.isNotEmpty) return Uint8List.fromList(data);
      return null;
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<ChatMessage> sendPhoto(String id, Uint8List bytes, {String caption = '', int reply = 0}) async {
    final auth = await _auth();
    final headers = Map<String, dynamic>.from(auth.headers ?? {});
    headers['Content-Type'] = 'application/octet-stream';
    final clean = caption.trim();
    if (clean.isNotEmpty) headers['X-Chat-Caption'] = Uri.encodeComponent(clean);
    if (reply > 0) headers['X-Reply-Id'] = '$reply';
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/threads/$id/photo',
      data: bytes,
      options: auth.copyWith(
        headers: headers,
        contentType: 'application/octet-stream',
        sendTimeout: const Duration(seconds: 40),
        receiveTimeout: const Duration(seconds: 40),
      ),
    );
    final message = _object(response)['message'];
    if (message is! Map) {
      throw DioException(
        requestOptions: response.requestOptions,
        message: 'The chat server did not return the photo.',
      );
    }
    return ChatMessage.fromJson(Map<String, dynamic>.from(message));
  }

  Future<Uint8List?> image(String id) async {
    if (id.isEmpty) return null;
    try {
      final auth = await _auth();
      final response = await _dio.get<dynamic>(
        '/api/v1/chat/images/$id',
        options: auth.copyWith(responseType: ResponseType.bytes, receiveTimeout: const Duration(seconds: 40)),
      );
      final data = response.data;
      if (data is Uint8List && data.isNotEmpty) return data;
      if (data is List<int> && data.isNotEmpty) return Uint8List.fromList(data);
      return null;
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<ChatMessage> sendVoice(String id, Uint8List bytes, int milliseconds, {int reply = 0}) async {
    final auth = await _auth();
    final headers = Map<String, dynamic>.from(auth.headers ?? {});
    headers['Content-Type'] = 'application/octet-stream';
    headers['X-Voice-Ms'] = '$milliseconds';
    if (reply > 0) headers['X-Reply-Id'] = '$reply';
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/threads/$id/voice',
      data: bytes,
      options: auth.copyWith(
        headers: headers,
        contentType: 'application/octet-stream',
        sendTimeout: const Duration(seconds: 40),
        receiveTimeout: const Duration(seconds: 40),
      ),
    );
    final message = _object(response)['message'];
    if (message is! Map) {
      throw DioException(
        requestOptions: response.requestOptions,
        message: 'The chat server did not return the voice note.',
      );
    }
    return ChatMessage.fromJson(Map<String, dynamic>.from(message));
  }

  Future<Uint8List> voice(String id) async {
    final auth = await _auth();
    final response = await _dio.get<dynamic>(
      '/api/v1/chat/voice/$id',
      options: auth.copyWith(responseType: ResponseType.bytes, receiveTimeout: const Duration(seconds: 40)),
    );
    final data = response.data;
    if (data is Uint8List && data.isNotEmpty) return data;
    if (data is List<int> && data.isNotEmpty) return Uint8List.fromList(data);
    throw DioException(requestOptions: response.requestOptions, message: 'That voice note could not be played.');
  }

  Future<Options> _auth() async {
    final token = await ChatSession.token();
    if (token == null) throw const ChatSignedOut();
    return Options(headers: {'X-Chat-Token': token});
  }

  Map<String, dynamic> _object(Response<dynamic> response) {
    final data = response.data;
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw DioException(
      requestOptions: response.requestOptions,
      message: 'The chat server did not answer.',
    );
  }
}

bool chatNeedsRegister(Object error) {
  if (error is ChatSignedOut) return true;
  return error is DioException && error.response?.statusCode == 401;
}

/// The sentence to show when a chat request fails.
String chatErrorText(Object error) {
  if (error is ChatSignedOut) {
    return 'Register a phone number or email to use chat.';
  }
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['error'] is Map) {
      final message = data['error']['message'];
      if (message is String && message.trim().isNotEmpty) return message.trim();
    }
    final own = error.message?.trim() ?? '';
    if (own.isNotEmpty && error.response == null && error.type == DioExceptionType.unknown) {
      return own;
    }
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.connectionError:
        return 'The chat server is waking. The first open can take a moment.';
      default:
        if (own.isNotEmpty && error.response == null) return own;
        break;
    }
  }
  return 'Chat is not reachable right now.';
}

/// Pictures sent inside a conversation, kept for this visit.
class ChatImages {
  static final ChatApi _api = ChatApi();
  static final Map<String, Uint8List> _bytes = {};
  static final Map<String, Future<Uint8List?>> _loading = {};

  static Future<Uint8List?> fetch(String id) {
    if (id.isEmpty) return Future<Uint8List?>.value(null);
    final pending = _loading[id];
    if (pending != null) return pending;
    final hit = _bytes[id];
    if (hit != null) {
      final done = Future<Uint8List?>.value(hit);
      _loading[id] = done;
      return done;
    }
    final future = _load(id);
    _loading[id] = future;
    return future;
  }

  static Future<Uint8List?> _load(String id) async {
    try {
      final bytes = await _api.image(id);
      if (bytes != null && bytes.isNotEmpty) {
        _bytes[id] = bytes;
        return bytes;
      }
    } catch (_) {}
    final pending = _loading.remove(id);
    if (pending != null) unawaited(pending);
    return null;
  }
}

/// Profile photos stay in memory for this visit, keyed by username and revision.
class ChatPhotos {
  static final ChatApi _api = ChatApi();
  static final Map<String, Uint8List> _bytes = {};
  static final Map<String, Future<Uint8List?>> _loading = {};

  static String _key(String username, int rev) => '${username.trim().toLowerCase()}:$rev';

  static Uint8List? cached(String username, int rev) {
    if (rev <= 0) return null;
    return _bytes[_key(username, rev)];
  }

  static void remember(String username, int rev, Uint8List bytes) {
    if (rev <= 0 || bytes.isEmpty) return;
    _bytes[_key(username, rev)] = bytes;
  }

  static Future<Uint8List?> fetch(String username, int rev) {
    final hit = cached(username, rev);
    if (hit != null) return Future<Uint8List?>.value(hit);
    if (rev <= 0 || username.trim().isEmpty) return Future<Uint8List?>.value(null);
    final key = _key(username, rev);
    return _loading.putIfAbsent(key, () async {
      try {
        final bytes = await _api.photo(username);
        if (bytes != null && bytes.isNotEmpty) _bytes[key] = bytes;
        return bytes;
      } catch (_) {
        return null;
      } finally {
        final pending = _loading.remove(key);
        if (pending != null) unawaited(pending);
      }
    });
  }
}
