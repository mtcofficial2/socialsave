import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/config/build_flags.dart';
import 'package:social_save/core/config/env_config.dart';

const chatTokenKey = 'chat.token.v1';
const chatUsernameKey = 'chat.username.v1';
const chatContactKey = 'chat.contact.v1';

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
  });

  final String id;
  final String username;
  final String phone;
  final String email;

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
    required this.lastText,
    required this.lastAt,
  });

  final String id;
  final String username;
  final String lastText;
  final DateTime? lastAt;

  factory ChatThreadSummary.fromJson(Map<String, dynamic> json) {
    final at = (json['lastAt'] as num?)?.toInt() ?? 0;
    return ChatThreadSummary(
      id: (json['id'] as String?)?.trim() ?? '',
      username: (json['username'] as String?)?.trim() ?? '',
      lastText: (json['lastText'] as String?)?.trim() ?? '',
      lastAt: at > 0 ? DateTime.fromMillisecondsSinceEpoch(at) : null,
    );
  }
}

/// One direct message. [name] is the sender's username.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.from,
    required this.name,
    required this.text,
    required this.links,
    required this.at,
  });

  final int id;
  final String from;
  final String name;
  final String text;
  final List<String> links;
  final DateTime at;

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final links = json['links'];
    return ChatMessage(
      id: (json['id'] as num?)?.toInt() ?? 0,
      from: (json['from'] as String?)?.trim() ?? '',
      name: (json['name'] as String?)?.trim().isNotEmpty == true ? (json['name'] as String).trim() : 'Someone',
      text: (json['text'] as String?)?.trim() ?? '',
      links: links is List ? links.whereType<String>().where((item) => item.startsWith('http')).toList() : const [],
      at: DateTime.fromMillisecondsSinceEpoch((json['at'] as num?)?.toInt() ?? 0),
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

  Future<List<ChatMessage>> messages(String id, int after) async {
    final response = await _dio.get<dynamic>(
      '/api/v1/chat/threads/$id',
      queryParameters: {'after': after},
      options: await _auth(),
    );
    final items = _object(response)['messages'];
    if (items is! List) return const [];
    return [
      for (final item in items)
        if (item is Map) ChatMessage.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  Future<ChatMessage> send(String id, String text) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/threads/$id',
      data: {'text': text},
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
