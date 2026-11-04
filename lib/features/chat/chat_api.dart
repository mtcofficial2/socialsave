import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
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
          if (entry.key is String && entry.value is num)
            entry.key as String: (entry.value as num).toInt(),
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

/// This device's chat account. The token is the sign-in. It is not a code.
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

  /// The in-app people list. The server still refuses anyone else.
  bool get isAdmin => chatUserIsAdmin(this);

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

/// One person who registered for chat. Only the admin request returns these.
class ChatDirectoryEntry {
  const ChatDirectoryEntry({
    required this.username,
    required this.phone,
    required this.email,
    required this.created,
    this.lastSeen,
    this.hasPassword = false,
  });

  final String username;
  final String phone;
  final String email;
  final DateTime? created;
  final DateTime? lastSeen;
  final bool hasPassword;

  String get contact {
    if (phone.isNotEmpty && email.isNotEmpty) return '$phone · $email';
    return phone.isNotEmpty ? phone : email;
  }

  factory ChatDirectoryEntry.fromJson(Map<String, dynamic> json) {
    final at = (json['created'] as num?)?.toInt() ?? 0;
    final seen = (json['lastSeen'] as num?)?.toInt() ?? 0;
    return ChatDirectoryEntry(
      username: (json['username'] as String?)?.trim() ?? '',
      phone: (json['phone'] as String?)?.trim() ?? '',
      email: (json['email'] as String?)?.trim() ?? '',
      created: at > 0 ? DateTime.fromMillisecondsSinceEpoch(at) : null,
      lastSeen: seen > 0 ? DateTime.fromMillisecondsSinceEpoch(seen) : null,
      hasPassword: json['hasPassword'] == true,
    );
  }
}

/// What a chat route was opened with. [name] is the private label, if any.
class ChatThreadTarget {
  const ChatThreadTarget({
    required this.username,
    this.name = '',
    this.group = false,
  });

  final String username;
  final String name;
  final bool group;
}

class ChatReaction {
  const ChatReaction({required this.user, required this.emoji});

  final String user;
  final String emoji;

  factory ChatReaction.fromJson(Map<String, dynamic> json) {
    return ChatReaction(
      user: (json['user'] as String?)?.trim() ?? '',
      emoji: (json['emoji'] as String?)?.trim() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'user': user, 'emoji': emoji};
}

class ChatMessageInfo {
  const ChatMessageInfo({
    required this.id,
    required this.at,
    this.editedAt,
    this.deliveredAt,
    this.readAt,
  });

  final int id;
  final DateTime at;
  final DateTime? editedAt;
  final DateTime? deliveredAt;
  final DateTime? readAt;

  factory ChatMessageInfo.fromJson(Map<String, dynamic> json) {
    DateTime? atOf(String key) {
      final value = (json[key] as num?)?.toInt() ?? 0;
      if (value <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(value);
    }

    return ChatMessageInfo(
      id: (json['id'] as num?)?.toInt() ?? 0,
      at: atOf('at') ?? DateTime.fromMillisecondsSinceEpoch(0),
      editedAt: atOf('editedAt'),
      deliveredAt: atOf('deliveredAt'),
      readAt: atOf('readAt'),
    );
  }
}

/// A group the signed-in account belongs to. [members] are usernames.
class ChatGroup {
  const ChatGroup({
    required this.id,
    required this.name,
    required this.code,
    this.members = const [],
  });

  final String id;
  final String name;
  final String code;
  final List<String> members;
}

/// True only for @daniel256 on 256703487378. The people list is still refused
/// by the server when this is wrong.
bool chatUserIsAdmin(ChatUser? user) {
  if (user == null) return false;
  final name = user.username
      .toLowerCase()
      .replaceFirst(RegExp(r'^@'), '')
      .trim();
  final digits = user.phone.replaceAll(RegExp(r'\D'), '');
  return name == 'daniel256' && digits == '256703487378';
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
    this.name = '',
    this.blocked = false,
    this.group = false,
    this.members = 0,
  });

  final String id;
  final String username;

  /// The name this account wants to see. Blank means show [username].
  final String name;

  String get label => name.trim().isNotEmpty ? name.trim() : username;
  final String lastText;
  final DateTime? lastAt;
  final int lastId;
  final String lastFrom;
  final String lastStatus;
  final int unread;
  final DateTime? lastSeen;
  final bool online;
  final int photoRev;
  final bool blocked;
  final bool group;
  final int members;

  ChatThreadSummary copyWith({
    String? lastText,
    DateTime? lastAt,
    int? lastId,
    String? lastFrom,
    String? lastStatus,
    int? unread,
    DateTime? lastSeen,
    bool? online,
    int? photoRev,
    String? name,
    bool? blocked,
    bool? group,
    int? members,
  }) {
    return ChatThreadSummary(
      id: id,
      username: username,
      name: name ?? this.name,
      lastText: lastText ?? this.lastText,
      lastAt: lastAt ?? this.lastAt,
      lastId: lastId ?? this.lastId,
      lastFrom: lastFrom ?? this.lastFrom,
      lastStatus: lastStatus ?? this.lastStatus,
      unread: unread ?? this.unread,
      lastSeen: lastSeen ?? this.lastSeen,
      online: online ?? this.online,
      photoRev: photoRev ?? this.photoRev,
      blocked: blocked ?? this.blocked,
      group: group ?? this.group,
      members: members ?? this.members,
    );
  }

  factory ChatThreadSummary.fromJson(Map<String, dynamic> json) {
    final at = (json['lastAt'] as num?)?.toInt() ?? 0;
    final seen = (json['lastSeen'] as num?)?.toInt() ?? 0;
    return ChatThreadSummary(
      id: (json['id'] as String?)?.trim() ?? '',
      username: (json['username'] as String?)?.trim() ?? '',
      name: (json['name'] as String?)?.trim() ?? '',
      lastText: (json['lastText'] as String?)?.trim() ?? '',
      lastAt: at > 0 ? DateTime.fromMillisecondsSinceEpoch(at) : null,
      lastId: (json['lastId'] as num?)?.toInt() ?? 0,
      lastFrom: (json['lastFrom'] as String?)?.trim() ?? '',
      lastStatus: (json['lastStatus'] as String?)?.trim() ?? '',
      unread: (json['unread'] as num?)?.toInt() ?? 0,
      lastSeen: seen > 0 ? DateTime.fromMillisecondsSinceEpoch(seen) : null,
      online: json['online'] == true && seen > 0,
      photoRev: (json['photoRev'] as num?)?.toInt() ?? 0,
      blocked: json['blocked'] == true,
      group: json['group'] == true,
      members: (json['members'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'name': name,
      'lastText': lastText,
      'lastAt': lastAt?.millisecondsSinceEpoch ?? 0,
      'lastId': lastId,
      'lastFrom': lastFrom,
      'lastStatus': lastStatus,
      'unread': unread,
      'lastSeen': lastSeen?.millisecondsSinceEpoch ?? 0,
      'photoRev': photoRev,
      'blocked': blocked,
      'group': group,
      'members': members,
    };
  }
}

/// One direct message. [name] is the sender's username.
class ChatSync {
  const ChatSync({
    required this.messages,
    this.updates = const [],
    this.removed = const [],
    this.pinned = const [],
    this.peerDelivered = 0,
    this.peerRead = 0,
    this.peerLastSeen,
    this.peerOnline = false,
    this.peerPhotoRev = 0,
    this.peerName = '',
    this.peerBlocked = false,
    this.peerGroup = false,
    this.peerMembers = const [],
    this.lastId = -1,
  });

  final List<ChatMessage> messages;
  final List<ChatMessage> updates;
  final List<int> removed;
  final List<int> pinned;
  final int peerDelivered;
  final int peerRead;
  final DateTime? peerLastSeen;
  final bool peerOnline;
  final int peerPhotoRev;
  final String peerName;
  final bool peerBlocked;
  final bool peerGroup;
  final List<String> peerMembers;

  /// Newest message id on the server, or -1 from an older server.
  final int lastId;
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
    this.song = '',
    this.songName = '',
    this.songMs = 0,
    this.songType = '',
    this.editedAt,
    this.reactions = const [],
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
  final String song;
  final String songName;
  final int songMs;
  final String songType;
  final DateTime? editedAt;
  final List<ChatReaction> reactions;
  final Uint8List? localBytes;
  final String pendingKind;

  bool get isVoice => voice.isNotEmpty || pendingKind == 'voice';
  bool get isPhoto => photo.isNotEmpty || pendingKind == 'photo';
  bool get isSong => song.isNotEmpty || pendingKind == 'song';
  bool get isEdited => editedAt != null;

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
      song: song,
      songName: songName,
      songMs: songMs,
      songType: songType,
      editedAt: editedAt,
      reactions: reactions,
      localBytes: localBytes,
      pendingKind: pendingKind,
    );
  }

  /// Keeps the quote and the picture bytes when the server answer omits them.
  ChatMessage withQuoteFrom(ChatMessage local) {
    final quote = replyText.isNotEmpty || local.replyText.isEmpty;
    final bytes = localBytes ?? local.localBytes;
    if (quote && bytes == localBytes && identical(reactions, local.reactions)) {
      return this;
    }
    return ChatMessage(
      id: id,
      from: from,
      name: name,
      text: text,
      links: links,
      at: at,
      status: status,
      voice: voice,
      voiceMs: voiceMs,
      voiceType: voiceType,
      reply: quote ? reply : local.reply,
      replyName: quote ? replyName : local.replyName,
      replyText: quote ? replyText : local.replyText,
      photo: photo,
      photoType: photoType,
      song: song,
      songName: songName,
      songMs: songMs,
      songType: songType,
      editedAt: editedAt,
      reactions: reactions,
      localBytes: bytes,
      pendingKind: pendingKind,
    );
  }

  ChatMessage withBytes(Uint8List bytes) {
    return ChatMessage(
      id: id,
      from: from,
      name: name,
      text: text,
      links: links,
      at: at,
      status: status,
      voice: voice,
      voiceMs: voiceMs,
      voiceType: voiceType,
      reply: reply,
      replyName: replyName,
      replyText: replyText,
      photo: photo,
      photoType: photoType,
      song: song,
      songName: songName,
      songMs: songMs,
      songType: songType,
      editedAt: editedAt,
      reactions: reactions,
      localBytes: bytes,
      pendingKind: pendingKind,
    );
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final links = json['links'];
    final rawReactions = json['reactions'];
    final edited = (json['editedAt'] as num?)?.toInt() ?? 0;
    return ChatMessage(
      id: (json['id'] as num?)?.toInt() ?? 0,
      from: (json['from'] as String?)?.trim() ?? '',
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : 'Someone',
      text: (json['text'] as String?)?.trim() ?? '',
      links: links is List
          ? links
                .whereType<String>()
                .where((item) => item.startsWith('http'))
                .toList()
          : const [],
      at: DateTime.fromMillisecondsSinceEpoch(
        (json['at'] as num?)?.toInt() ?? 0,
      ),
      status: (json['status'] as String?)?.trim() ?? '',
      voice: (json['voice'] as String?)?.trim() ?? '',
      voiceMs: (json['voiceMs'] as num?)?.toInt() ?? 0,
      voiceType: (json['voiceType'] as String?)?.trim() ?? '',
      reply: (json['reply'] as num?)?.toInt() ?? 0,
      replyName: (json['replyName'] as String?)?.trim() ?? '',
      replyText: (json['replyText'] as String?)?.trim() ?? '',
      photo: (json['photo'] as String?)?.trim() ?? '',
      photoType: (json['photoType'] as String?)?.trim() ?? '',
      song: (json['song'] as String?)?.trim() ?? '',
      songName: (json['songName'] as String?)?.trim() ?? '',
      songMs: (json['songMs'] as num?)?.toInt() ?? 0,
      songType: (json['songType'] as String?)?.trim() ?? '',
      editedAt: edited > 0 ? DateTime.fromMillisecondsSinceEpoch(edited) : null,
      reactions: rawReactions is List
          ? [
              for (final item in rawReactions)
                if (item is Map)
                  ChatReaction.fromJson(Map<String, dynamic>.from(item)),
            ]
          : const [],
      pendingKind: (json['pendingKind'] as String?)?.trim() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'from': from,
      'name': name,
      'text': text,
      'links': links,
      'at': at.millisecondsSinceEpoch,
      'status': status,
      'voice': voice,
      'voiceMs': voiceMs,
      'voiceType': voiceType,
      'reply': reply,
      'replyName': replyName,
      'replyText': replyText,
      'photo': photo,
      'photoType': photoType,
      if (song.isNotEmpty) 'song': song,
      if (songName.isNotEmpty) 'songName': songName,
      if (songMs > 0) 'songMs': songMs,
      if (songType.isNotEmpty) 'songType': songType,
      if (editedAt != null) 'editedAt': editedAt!.millisecondsSinceEpoch,
      if (reactions.isNotEmpty)
        'reactions': [for (final item in reactions) item.toJson()],
      if (pendingKind.isNotEmpty) 'pendingKind': pendingKind,
    };
  }
}

class ChatOutgoing {
  const ChatOutgoing(this.message, {this.held = false});

  final ChatMessage message;
  final bool held;
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
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }
  return 'https://socialsave-api-p2tm.onrender.com';
}

class ChatApi {
  ChatApi({Dio? dio, String? baseUrl})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: baseUrl ?? chatApiBaseUrl(),
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 70),
              sendTimeout: const Duration(seconds: 20),
              headers: {
                'Accept': 'application/json',
                'Content-Type': 'application/json',
                if (EnvConfig.hasApiKey)
                  'Authorization': 'Bearer ${EnvConfig.apiKey}',
              },
            ),
          );

  final Dio _dio;

  Future<ChatRegistration> register({
    String phone = '',
    String email = '',
    required String username,
    required String password,
  }) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/register',
      data: {
        'username': username,
        'password': password,
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
    return ChatRegistration(
      token: token,
      user: ChatUser.fromJson(Map<String, dynamic>.from(user)),
    );
  }

  /// Where the server keeps accounts, from the last [directory] call:
  /// 's3', 's3-error', 'temporary', or empty when the server did not say.
  String lastStorage = '';

  Future<List<ChatDirectoryEntry>> directory() async {
    final response = await _dio.get<dynamic>(
      '/api/v1/chat/admin/users',
      options: await _auth(),
    );
    final body = _object(response);
    lastStorage = (body['storage'] as String?)?.trim() ?? '';
    final items = body['users'];
    if (items is! List) return const [];
    return [
      for (final item in items)
        if (item is Map)
          ChatDirectoryEntry.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  Future<ChatUser> me() async {
    final response = await _dio.get<dynamic>(
      '/api/v1/chat/me',
      options: await _auth(),
    );
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
    final response = await _dio.get<dynamic>(
      '/api/v1/chat/threads',
      options: await _auth(),
    );
    final items = _object(response)['threads'];
    if (items is! List) return const [];
    return [
      for (final item in items)
        if (item is Map)
          ChatThreadSummary.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  /// Stores the name this account sees for [username]. Blank, or the username
  /// itself, clears it. Returns the name the server kept.
  Future<String> setSeenName(String username, String name) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/saved',
      data: {'username': username, 'name': name},
      options: await _auth(),
    );
    return (_object(response)['name'] as String?)?.trim() ?? '';
  }

  Future<ChatThreadSummary> openThread(
    String username, {
    String? seenName,
  }) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/threads',
      data: {
        'username': username,
        'name': ?seenName,
      },
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
    return ChatThreadSummary(
      id: id,
      username: name,
      name: (body['name'] as String?)?.trim() ?? '',
      lastText: '',
      lastAt: null,
    );
  }

  Future<ChatSync> messages(String id, int after, {int since = 0}) async {
    final response = await _dio.get<dynamic>(
      '/api/v1/chat/threads/$id',
      queryParameters: {
        'after': after,
        if (since > 0) 'since': since,
      },
      options: await _auth(),
    );
    final body = _object(response);
    final items = body['messages'];
    final changed = body['updates'];
    final removed = body['removed'];
    final pinned = body['pinned'];
    final peer = body['peer'];
    var delivered = 0;
    var read = 0;
    DateTime? seen;
    var online = false;
    var photoRev = 0;
    var peerName = '';
    var peerBlocked = false;
    var peerGroup = false;
    final peerMembers = <String>[];
    if (peer is Map) {
      delivered = (peer['delivered'] as num?)?.toInt() ?? 0;
      read = (peer['read'] as num?)?.toInt() ?? 0;
      final at = (peer['lastSeen'] as num?)?.toInt() ?? 0;
      if (at > 0) seen = DateTime.fromMillisecondsSinceEpoch(at);
      online = peer['online'] == true && seen != null;
      photoRev = (peer['photoRev'] as num?)?.toInt() ?? 0;
      peerName = (peer['name'] as String?)?.trim() ?? '';
      peerBlocked = peer['blocked'] == true;
      peerGroup = peer['group'] == true;
      final names = peer['members'];
      if (names is List) {
        for (final name in names) {
          if (name is String && name.trim().isNotEmpty) {
            peerMembers.add(name.trim());
          }
        }
      }
    }
    List<ChatMessage> readMessages(Object? raw) {
      if (raw is! List) return const [];
      return [
        for (final item in raw)
          if (item is Map)
            ChatMessage.fromJson(Map<String, dynamic>.from(item)),
      ];
    }

    return ChatSync(
      peerDelivered: delivered,
      peerRead: read,
      peerLastSeen: seen,
      peerOnline: online,
      peerPhotoRev: photoRev,
      peerName: peerName,
      peerBlocked: peerBlocked,
      peerGroup: peerGroup,
      peerMembers: peerMembers,
      lastId: (body['lastId'] as num?)?.toInt() ?? -1,
      removed: [
        if (removed is List)
          for (final item in removed)
            if (item is num && item > 0) item.toInt(),
      ],
      pinned: [
        if (pinned is List)
          for (final item in pinned)
            if (item is num && item > 0) item.toInt(),
      ],
      messages: readMessages(items),
      updates: readMessages(changed),
    );
  }

  Future<void> unsend(String id, int messageId) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/threads/$id/unsend',
      data: {'id': messageId},
      options: await _auth(),
    );
  }

  Future<ChatMessage> react(String id, int messageId, String emoji) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/threads/$id/react',
      data: {'id': messageId, 'emoji': emoji},
      options: await _auth(),
    );
    return _message(response, 'That reaction could not be saved.');
  }

  Future<ChatMessage> edit(String id, int messageId, String text) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/threads/$id/edit',
      data: {'id': messageId, 'text': text},
      options: await _auth(),
    );
    return _message(response, 'That message could not be edited.');
  }

  Future<List<int>> pin(String id, int messageId) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/threads/$id/pin',
      data: {'id': messageId},
      options: await _auth(),
    );
    final raw = _object(response)['pinned'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is num && item > 0) item.toInt(),
    ];
  }

  Future<ChatMessageInfo> info(String id, int messageId) async {
    final response = await _dio.get<dynamic>(
      '/api/v1/chat/threads/$id/info',
      queryParameters: {'id': messageId},
      options: await _auth(),
    );
    final info = _object(response)['info'];
    if (info is! Map) {
      throw DioException(
        requestOptions: response.requestOptions,
        message: 'That message info could not be read.',
      );
    }
    return ChatMessageInfo.fromJson(Map<String, dynamic>.from(info));
  }

  Future<bool> block(String username, {required bool on}) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/block',
      data: {'username': username, 'on': on},
      options: await _auth(),
    );
    return _object(response)['blocked'] == true;
  }

  Future<void> logout() async {
    await _dio.post<dynamic>(
      '/api/v1/chat/logout',
      options: await _auth(),
    );
  }

  Future<ChatGroup> createGroup(String name) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/groups',
      data: {'name': name},
      options: await _auth(),
    );
    return _group(response);
  }

  Future<ChatGroup> joinGroup(String code) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/groups/join',
      data: {'code': code},
      options: await _auth(),
    );
    return _group(response);
  }

  Future<ChatGroup> group(String id) async {
    final response = await _dio.get<dynamic>(
      '/api/v1/chat/groups/$id',
      options: await _auth(),
    );
    return _group(response);
  }

  Future<String> renameGroup(String id, String name) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/groups/$id/name',
      data: {'name': name},
      options: await _auth(),
    );
    return (_object(response)['name'] as String?)?.trim() ?? '';
  }

  Future<void> leaveGroup(String id) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/groups/$id/leave',
      options: await _auth(),
    );
  }

  Future<ChatMessage> sendSong(
    String id,
    Uint8List bytes, {
    required String name,
    int milliseconds = 0,
    int reply = 0,
  }) async {
    final auth = await _auth();
    final headers = Map<String, dynamic>.from(auth.headers ?? {});
    headers['Content-Type'] = 'application/octet-stream';
    headers['X-Song-Name'] = Uri.encodeComponent(name.trim());
    if (milliseconds > 0) headers['X-Song-Ms'] = '$milliseconds';
    if (reply > 0) headers['X-Reply-Id'] = '$reply';
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/threads/$id/song',
      data: bytes,
      options: auth.copyWith(
        headers: headers,
        contentType: 'application/octet-stream',
        sendTimeout: const Duration(seconds: 90),
        receiveTimeout: const Duration(seconds: 90),
      ),
    );
    return _message(response, 'That song could not be sent.');
  }

  Future<Uint8List> song(String id) async {
    final auth = await _auth();
    final response = await _dio.get<dynamic>(
      '/api/v1/chat/songs/$id',
      options: auth.copyWith(
        responseType: ResponseType.bytes,
        receiveTimeout: const Duration(seconds: 90),
      ),
    );
    final data = response.data;
    if (data is Uint8List && data.isNotEmpty) return data;
    if (data is List<int> && data.isNotEmpty) return Uint8List.fromList(data);
    throw DioException(
      requestOptions: response.requestOptions,
      message: 'That song could not be played.',
    );
  }

  ChatMessage _message(Response<dynamic> response, String missing) {
    final message = _object(response)['message'];
    if (message is! Map) {
      throw DioException(
        requestOptions: response.requestOptions,
        message: missing,
      );
    }
    return ChatMessage.fromJson(Map<String, dynamic>.from(message));
  }

  ChatGroup _group(Response<dynamic> response) {
    final body = _object(response);
    final id = (body['id'] as String?)?.trim() ?? '';
    final name = (body['name'] as String?)?.trim() ?? '';
    if (id.isEmpty || name.isEmpty) {
      throw DioException(
        requestOptions: response.requestOptions,
        message: 'The chat server did not return that group.',
      );
    }
    final raw = body['members'];
    return ChatGroup(
      id: id,
      name: name,
      code: (body['code'] as String?)?.trim() ?? '',
      members: [
        if (raw is List)
          for (final item in raw)
            if (item is String && item.trim().isNotEmpty) item.trim(),
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
      data: {'text': text, if (reply > 0) 'reply': reply},
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
      throw DioException(
        requestOptions: response.requestOptions,
        message: 'That photo could not be saved.',
      );
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

  Future<ChatOutgoing> sendPhoto(
    String id,
    Uint8List bytes, {
    String caption = '',
    int reply = 0,
  }) async {
    final auth = await _auth();
    final headers = Map<String, dynamic>.from(auth.headers ?? {});
    headers['Content-Type'] = 'application/octet-stream';
    final clean = caption.trim();
    if (clean.isNotEmpty) {
      headers['X-Chat-Caption'] = Uri.encodeComponent(clean);
    }
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
    return ChatOutgoing(
      ChatMessage.fromJson(Map<String, dynamic>.from(message)),
      held: _object(response)['held'] == true,
    );
  }

  Future<Uint8List?> image(String id) async {
    if (id.isEmpty) return null;
    try {
      final auth = await _auth();
      final response = await _dio.get<dynamic>(
        '/api/v1/chat/images/$id',
        options: auth.copyWith(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 40),
        ),
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

  Future<ChatMessage> sendVoice(
    String id,
    Uint8List bytes,
    int milliseconds, {
    int reply = 0,
  }) async {
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
      options: auth.copyWith(
        responseType: ResponseType.bytes,
        receiveTimeout: const Duration(seconds: 40),
      ),
    );
    final data = response.data;
    if (data is Uint8List && data.isNotEmpty) return data;
    if (data is List<int> && data.isNotEmpty) return Uint8List.fromList(data);
    throw DioException(
      requestOptions: response.requestOptions,
      message: 'That voice note could not be played.',
    );
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
    return 'Sign in with your phone or email and username to use chat.';
  }
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['error'] is Map) {
      final message = data['error']['message'];
      if (message is String && message.trim().isNotEmpty) return message.trim();
    }
    final own = error.message?.trim() ?? '';
    if (own.isNotEmpty &&
        error.response == null &&
        error.type == DioExceptionType.unknown) {
      return own;
    }
    final detail = '${error.error ?? ''} $own'.toLowerCase();
    if (detail.contains('host lookup') ||
        detail.contains('no address associated')) {
      return 'This network cannot find the chat server. Try mobile data, another Wi-Fi, or a different DNS.';
    }
    final code = error.response?.statusCode;
    if (code != null && code >= 400) {
      return 'The chat server answered with error $code. Try again in a moment.';
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
  // Keep the real reason visible so a failure can be diagnosed.
  final why = error is DioException
      ? '${error.type.name} ${error.response?.statusCode ?? ''} ${error.message ?? ''} ${error.error ?? ''}'
      : '${error.runtimeType}: $error';
  debugPrint('chat error: $why');
  final short = why.trim().length > 140 ? why.trim().substring(0, 140) : why.trim();
  return 'Chat is not reachable right now. ($short)';
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

  /// Called when a profile photo is kept, so a notification can use it later.
  static void Function(String username, int rev, Uint8List bytes)? onStored;

  static String _key(String username, int rev) =>
      '${username.trim().toLowerCase()}:$rev';

  static Uint8List? cached(String username, int rev) {
    if (rev <= 0) return null;
    return _bytes[_key(username, rev)];
  }

  static void remember(String username, int rev, Uint8List bytes) {
    if (rev <= 0 || bytes.isEmpty) return;
    _bytes[_key(username, rev)] = bytes;
    onStored?.call(username, rev, bytes);
  }

  /// Any profile photo already in memory for [username], newest revision first.
  static Uint8List? anyCached(String username) {
    final name = username.trim().toLowerCase();
    if (name.isEmpty) return null;
    final prefix = '$name:';
    Uint8List? best;
    var bestRev = -1;
    for (final entry in _bytes.entries) {
      if (!entry.key.startsWith(prefix) || entry.value.isEmpty) continue;
      final rev = int.tryParse(entry.key.substring(prefix.length)) ?? -1;
      if (rev < bestRev) continue;
      bestRev = rev;
      best = entry.value;
    }
    return best;
  }

  /// Bytes for a chat notification. Uses the known revision, then any photo
  /// already on this device, then the current profile from the server.
  static Future<Uint8List?> forAlert(String username, int rev) async {
    if (rev > 0) return fetch(username, rev);
    final name = username.trim();
    if (name.isEmpty) return null;
    final saved = anyCached(name);
    if (saved != null) return saved;
    try {
      final bytes = await _api.photo(name);
      if (bytes != null && bytes.isNotEmpty) {
        _bytes['${name.toLowerCase()}:$rev'] = bytes;
        onStored?.call(name, rev, bytes);
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> fetch(String username, int rev) {
    final hit = cached(username, rev);
    if (hit != null) return Future<Uint8List?>.value(hit);
    if (rev <= 0 || username.trim().isEmpty) {
      return Future<Uint8List?>.value(null);
    }
    final key = _key(username, rev);
    return _loading.putIfAbsent(key, () async {
      try {
        final bytes = await _api.photo(username);
        if (bytes != null && bytes.isNotEmpty) remember(username, rev, bytes);
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
