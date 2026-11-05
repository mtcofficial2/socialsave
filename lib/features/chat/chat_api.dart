import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/config/build_flags.dart';
import 'package:social_save/core/config/env_config.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/platform/device_name_io.dart'
    if (dart.library.html) 'package:social_save/core/platform/device_name_stub.dart';
import 'package:social_save/core/platform/plat.dart';

const chatTokenKey = 'chat.token.v1';
const chatUsernameKey = 'chat.username.v1';
const chatContactKey = 'chat.contact.v1';
const chatReadKey = 'chat.read.v1';
const chatInstallKey = 'socialsave.install.v1';

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
    this.onlinePrivacy = 'everyone',
    this.seenPrivacy = 'everyone',
    this.photoPrivacy = 'everyone',
    this.receipts = 'everyone',
  });

  final String id;
  final String username;
  final String phone;
  final String email;
  final int photoRev;

  /// everyone, contacts, or nobody. Empty from the server means everyone.
  final String onlinePrivacy;
  final String seenPrivacy;
  final String photoPrivacy;

  /// everyone shows read receipts. nobody stores the read without announcing it.
  final String receipts;

  ChatUser copyWith({
    int? photoRev,
    String? onlinePrivacy,
    String? seenPrivacy,
    String? photoPrivacy,
    String? receipts,
  }) {
    return ChatUser(
      id: id,
      username: username,
      phone: phone,
      email: email,
      photoRev: photoRev ?? this.photoRev,
      onlinePrivacy: onlinePrivacy ?? this.onlinePrivacy,
      seenPrivacy: seenPrivacy ?? this.seenPrivacy,
      photoPrivacy: photoPrivacy ?? this.photoPrivacy,
      receipts: receipts ?? this.receipts,
    );
  }

  String get contact {
    if (email.isNotEmpty && phone.isNotEmpty) return '$phone · $email';
    return email.isNotEmpty ? email : phone;
  }

  /// The in-app people list. The server still refuses anyone else.
  bool get isAdmin => chatUserIsAdmin(this);

  factory ChatUser.fromJson(Map<String, dynamic> json) {
    final privacy = json['privacy'];
    String audience(String key) {
      if (privacy is! Map) return 'everyone';
      final value = (privacy[key] as String?)?.trim() ?? '';
      return value.isEmpty ? 'everyone' : value;
    }

    return ChatUser(
      id: (json['id'] as String?)?.trim() ?? '',
      username: (json['username'] as String?)?.trim() ?? '',
      phone: (json['phone'] as String?)?.trim() ?? '',
      email: (json['email'] as String?)?.trim() ?? '',
      photoRev: (json['photoRev'] as num?)?.toInt() ?? 0,
      onlinePrivacy: audience('online'),
      seenPrivacy: audience('lastSeen'),
      photoPrivacy: audience('photo'),
      receipts: audience('receipts'),
    );
  }
}

class ChatRegistration {
  const ChatRegistration({
    required this.token,
    required this.user,
    this.recovery = '',
  });

  final String token;
  final ChatUser user;

  /// Shown once, when this account first gets a recovery code.
  final String recovery;
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

/// People and devices for the admin monitor. Anyone else is refused.
class ChatAdminSnapshot {
  const ChatAdminSnapshot({
    required this.people,
    required this.devices,
    required this.storage,
  });

  final List<ChatDirectoryEntry> people;
  final List<ChatDeviceEntry> devices;
  final String storage;
}

/// One install. [id] is a random id from that device, not a serial number.
class ChatDeviceEntry {
  const ChatDeviceEntry({
    required this.id,
    required this.platform,
    required this.version,
    required this.username,
    this.name = '',
    this.model = '',
    this.downloads = 0,
    required this.first,
    required this.seen,
    this.lastDownload,
  });

  final String id;
  final String platform;
  final String version;
  final String username;
  final String name;
  final String model;
  final int downloads;
  final DateTime? first;
  final DateTime? seen;
  final DateTime? lastDownload;

  factory ChatDeviceEntry.fromJson(Map<String, dynamic> json) {
    final first = (json['first'] as num?)?.toInt() ?? 0;
    final seen = (json['seen'] as num?)?.toInt() ?? 0;
    return ChatDeviceEntry(
      id: (json['id'] as String?)?.trim() ?? '',
      platform: (json['platform'] as String?)?.trim() ?? '',
      version: (json['version'] as String?)?.trim() ?? '',
      username: (json['username'] as String?)?.trim() ?? '',
      name: (json['name'] as String?)?.trim() ?? '',
      model: (json['model'] as String?)?.trim() ?? '',
      downloads: (json['downloads'] as num?)?.toInt() ?? 0,
      first: first > 0 ? DateTime.fromMillisecondsSinceEpoch(first) : null,
      seen: seen > 0 ? DateTime.fromMillisecondsSinceEpoch(seen) : null,
      lastDownload: ((json['lastDownload'] as num?)?.toInt() ?? 0) > 0
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['lastDownload'] as num).toInt(),
            )
          : null,
    );
  }
}

List<ChatDirectoryEntry> _directoryRows(Object? items) {
  if (items is! List) return const [];
  return [
    for (final item in items)
      if (item is Map)
        ChatDirectoryEntry.fromJson(Map<String, dynamic>.from(item)),
  ];
}

List<ChatDeviceEntry> _deviceRows(Object? items) {
  if (items is! List) return const [];
  return [
    for (final item in items)
      if (item is Map) ChatDeviceEntry.fromJson(Map<String, dynamic>.from(item)),
  ];
}

/// A random 32-character id stored on this device. Null when one cannot be made.
Future<String?> _installId() async {
  final prefs = await SharedPreferences.getInstance();
  final current = prefs.getString(chatInstallKey)?.trim().toLowerCase() ?? '';
  if (RegExp(r'^[a-f0-9]{32}$').hasMatch(current)) return current;
  final random = Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  final id = buffer.toString();
  await prefs.setString(chatInstallKey, id);
  return id;
}

/// The kind of device the server accepts. Null is not reported.
String? chatDevicePlatform() {
  if (Plat.isWeb) return 'web';
  if (Plat.isAndroid) return 'android';
  if (Plat.isIOS) return 'ios';
  if (Plat.isWindows) return 'windows';
  if (Plat.isMacOS) return 'macos';
  if (Plat.isLinux) return 'linux';
  return null;
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
    this.about = '',
    this.rules = '',
    this.announce = false,
    this.owner = '',
    this.admins = const [],
    this.inviteExp = 0,
  });

  final String id;
  final String name;
  final String code;
  final List<String> members;
  final String about;
  final String rules;
  final bool announce;
  final String owner;
  final List<String> admins;
  final int inviteExp;
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
    this.request = false,
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
  final bool request;

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
    bool? request,
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
      request: request ?? this.request,
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
      request: json['request'] == true,
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
      'request': request,
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
    this.peerRequest = false,
    this.groupAbout = '',
    this.groupRules = '',
    this.groupAnnounce = false,
    this.groupOwner = '',
    this.groupAdmins = const [],
    this.inviteExp = 0,
    this.vanish = 0,
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
  final bool peerRequest;
  final String groupAbout;
  final String groupRules;
  final bool groupAnnounce;
  final String groupOwner;
  final List<String> groupAdmins;
  final int inviteExp;
  final int vanish;
}

class ChatPoll {
  const ChatPoll({
    required this.question,
    required this.choices,
    this.votes = const {},
    this.closes,
    this.closed = false,
  });

  final String question;
  final List<String> choices;
  final Map<String, int> votes;
  final DateTime? closes;
  final bool closed;

  factory ChatPoll.fromJson(Map<String, dynamic> json) {
    final rawChoices = json['choices'];
    final rawVotes = json['votes'];
    final closes = (json['closes'] as num?)?.toInt() ?? 0;
    return ChatPoll(
      question: (json['question'] as String?)?.trim() ?? '',
      choices: [
        if (rawChoices is List)
          for (final item in rawChoices)
            if (item is String && item.trim().isNotEmpty) item.trim(),
      ],
      votes: {
        if (rawVotes is Map)
          for (final entry in rawVotes.entries)
            if (entry.key is String && entry.value is num)
              (entry.key as String): (entry.value as num).toInt(),
      },
      closes: closes > 0 ? DateTime.fromMillisecondsSinceEpoch(closes) : null,
      closed: json['closed'] == true,
    );
  }
}

class ChatCard {
  const ChatCard({required this.name, this.phone = '', this.username = ''});

  final String name;
  final String phone;
  final String username;

  factory ChatCard.fromJson(Map<String, dynamic> json) {
    return ChatCard(
      name: (json['name'] as String?)?.trim() ?? '',
      phone: (json['phone'] as String?)?.trim() ?? '',
      username: (json['username'] as String?)?.trim() ?? '',
    );
  }
}

class ChatPlace {
  const ChatPlace({required this.lat, required this.lng, this.label = ''});

  final double lat;
  final double lng;
  final String label;

  String get link {
    final la = lat.toStringAsFixed(5);
    final ln = lng.toStringAsFixed(5);
    return 'https://maps.google.com/?q=$la,$ln';
  }

  factory ChatPlace.fromJson(Map<String, dynamic> json) {
    return ChatPlace(
      lat: (json['lat'] as num?)?.toDouble() ?? 0,
      lng: (json['lng'] as num?)?.toDouble() ?? 0,
      label: (json['label'] as String?)?.trim() ?? '',
    );
  }
}

class ChatStatusNote {
  const ChatStatusNote({
    required this.id,
    required this.name,
    required this.text,
    required this.at,
    this.audience = 'all',
    this.views = const [],
  });

  final String id;
  final String name;
  final String text;
  final DateTime at;
  final String audience;
  final List<String> views;

  factory ChatStatusNote.fromJson(Map<String, dynamic> json) {
    final rawViews = json['views'];
    return ChatStatusNote(
      id: (json['id'] as String?)?.trim() ?? '',
      name: (json['name'] as String?)?.trim() ?? '',
      text: (json['text'] as String?)?.trim() ?? '',
      at: DateTime.fromMillisecondsSinceEpoch((json['at'] as num?)?.toInt() ?? 0),
      audience: (json['audience'] as String?)?.trim() ?? 'all',
      views: [
        if (rawViews is List)
          for (final item in rawViews)
            if (item is String && item.trim().isNotEmpty) item.trim(),
      ],
    );
  }
}

class ChatScheduleNote {
  const ChatScheduleNote({
    required this.id,
    required this.thread,
    required this.text,
    required this.sendAt,
  });

  final String id;
  final String thread;
  final String text;
  final DateTime sendAt;

  factory ChatScheduleNote.fromJson(Map<String, dynamic> json) {
    return ChatScheduleNote(
      id: (json['id'] as String?)?.trim() ?? '',
      thread: (json['thread'] as String?)?.trim() ?? '',
      text: (json['text'] as String?)?.trim() ?? '',
      sendAt: DateTime.fromMillisecondsSinceEpoch(
        (json['sendAt'] as num?)?.toInt() ?? 0,
      ),
    );
  }
}

class ChatStarred {
  const ChatStarred({
    required this.thread,
    required this.id,
    required this.text,
  });

  final String thread;
  final int id;
  final String text;

  factory ChatStarred.fromJson(Map<String, dynamic> json) {
    return ChatStarred(
      thread: (json['thread'] as String?)?.trim() ?? '',
      id: (json['id'] as num?)?.toInt() ?? 0,
      text: (json['text'] as String?)?.trim() ?? '',
    );
  }
}

class ChatFolder {
  const ChatFolder({
    required this.id,
    required this.name,
    this.threads = const [],
  });

  final String id;
  final String name;
  final List<String> threads;

  factory ChatFolder.fromJson(Map<String, dynamic> json) {
    final raw = json['threads'];
    return ChatFolder(
      id: (json['id'] as String?)?.trim() ?? '',
      name: (json['name'] as String?)?.trim() ?? '',
      threads: [
        if (raw is List)
          for (final item in raw)
            if (item is String && item.trim().isNotEmpty) item.trim(),
      ],
    );
  }
}

class ChatDeviceSession {
  const ChatDeviceSession({
    required this.id,
    this.name = '',
    this.platform = '',
    this.current = false,
    this.seen,
  });

  final String id;
  final String name;
  final String platform;
  final bool current;
  final DateTime? seen;

  factory ChatDeviceSession.fromJson(Map<String, dynamic> json) {
    final at = (json['seen'] as num?)?.toInt() ?? 0;
    return ChatDeviceSession(
      id: (json['id'] as String?)?.trim() ?? '',
      name: (json['name'] as String?)?.trim() ?? '',
      platform: (json['platform'] as String?)?.trim() ?? '',
      current: json['current'] == true,
      seen: at > 0 ? DateTime.fromMillisecondsSinceEpoch(at) : null,
    );
  }
}

class ChatCallRecord {
  const ChatCallRecord({
    required this.id,
    required this.thread,
    required this.state,
    this.fromName = '',
    this.fromId = '',
    this.to = '',
    this.offer = '',
    this.answer = '',
    this.dur = 0,
  });

  final String id;
  final String thread;
  final String state;
  final String fromName;
  final String fromId;
  final String to;
  final String offer;
  final String answer;
  final int dur;

  bool get live => state == 'ringing' || state == 'active';

  factory ChatCallRecord.fromJson(Map<String, dynamic> json) {
    final named = (json['fromName'] as String?)?.trim() ?? '';
    final fromIdField = (json['fromId'] as String?)?.trim() ?? '';
    final from = (json['from'] as String?)?.trim() ?? '';
    return ChatCallRecord(
      id: (json['id'] as String?)?.trim() ?? '',
      thread: (json['thread'] as String?)?.trim() ?? '',
      state: (json['state'] as String?)?.trim() ?? '',
      fromName: named.isNotEmpty
          ? named
          : (fromIdField.isNotEmpty ? from : ''),
      fromId: fromIdField.isNotEmpty ? fromIdField : from,
      to: (json['to'] as String?)?.trim() ?? '',
      offer: (json['offer'] as String?)?.trim() ?? '',
      answer: (json['answer'] as String?)?.trim() ?? '',
      dur: (json['dur'] as num?)?.toInt() ?? 0,
    );
  }
}

/// libwebrtc treats an offer with no trailing CRLF as empty. The stored
/// offer is trimmed, which is why Accept failed with SessionDescription is NULL.
String callSdp(String raw) {
  var text = raw.replaceAll('\u0000', '');
  if (!text.contains('\n') && text.contains(r'\n')) {
    text = text.replaceAll(r'\r\n', '\n').replaceAll(r'\n', '\n').replaceAll(r'\r', '');
  }
  text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (!text.startsWith('v=0')) return '';
  return '${text.replaceAll('\n', '\r\n')}\r\n';
}

/// The server has closed this call. A live screen should leave.
bool callIsOver(String state) {
  switch (state) {
    case 'declined':
    case 'ended':
    case 'missed':
    case 'cancelled':
      return true;
    default:
      return false;
  }
}

/// True when the call this phone is in has finished, or that id is gone.
bool watchedCallFinished(List<ChatCallRecord> rows, String id) {
  if (id.isEmpty) return false;
  for (final row in rows) {
    if (row.id != id) continue;
    return callIsOver(row.state);
  }
  return true;
}

/// Ringing out stays a small bar. A picked-up call, and a call arriving here, fill the screen.
bool callUsesFullScreen({required bool outgoing, required String status}) {
  if (status == 'active') return true;
  return !outgoing && status == 'ringing';
}

/// Words shown while a call screen closes.
String callExitLabel(String kind) {
  switch (kind) {
    case 'declined':
      return 'Declined';
    case 'missed':
      return 'Missed call';
    case 'cancelled':
      return 'Cancelled';
    default:
      return 'Call ended';
  }
}

/// A ringing call placed by someone else. The caller is not rung again.
ChatCallRecord? incomingRing(List<ChatCallRecord> rows, String me) {
  final mine = me.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
  for (final call in rows) {
    if (call.state != 'ringing' || call.id.isEmpty) continue;
    final who = call.fromName.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
    if (who.isEmpty || who == mine) continue;
    return call;
  }
  return null;
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
    this.poll,
    this.card,
    this.place,
    this.expires,
    this.call = '',
    this.callMs = 0,
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
  final ChatPoll? poll;
  final ChatCard? card;
  final ChatPlace? place;
  final DateTime? expires;
  final String call;
  final int callMs;

  bool get isVoice => voice.isNotEmpty || pendingKind == 'voice';
  bool get isPhoto => photo.isNotEmpty || pendingKind == 'photo';
  bool get isSong => song.isNotEmpty || pendingKind == 'song';
  bool get isEdited => editedAt != null;
  bool get isPoll => poll != null;
  bool get isCard => card != null;
  bool get isPlace => place != null;
  bool get isCall => call.isNotEmpty;

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
      poll: poll,
      card: card,
      place: place,
      expires: expires,
      call: call,
      callMs: callMs,
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
      poll: poll,
      card: card,
      place: place,
      expires: expires,
      call: call,
      callMs: callMs,
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
      poll: poll,
      card: card,
      place: place,
      expires: expires,
      call: call,
      callMs: callMs,
    );
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final links = json['links'];
    final rawReactions = json['reactions'];
    final edited = (json['editedAt'] as num?)?.toInt() ?? 0;
    final expiresAt = (json['expires'] as num?)?.toInt() ?? 0;
    final rawPoll = json['poll'];
    final rawCard = json['card'];
    final rawPlace = json['place'];
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
      poll: rawPoll is Map
          ? ChatPoll.fromJson(Map<String, dynamic>.from(rawPoll))
          : null,
      card: rawCard is Map
          ? ChatCard.fromJson(Map<String, dynamic>.from(rawCard))
          : null,
      place: rawPlace is Map
          ? ChatPlace.fromJson(Map<String, dynamic>.from(rawPlace))
          : null,
      expires: expiresAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(expiresAt)
          : null,
      call: (json['call'] as String?)?.trim() ?? '',
      callMs: (json['callMs'] as num?)?.toInt() ?? 0,
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
      if (poll != null)
        'poll': {
          'question': poll!.question,
          'choices': poll!.choices,
          if (poll!.votes.isNotEmpty) 'votes': poll!.votes,
          if (poll!.closes != null)
            'closes': poll!.closes!.millisecondsSinceEpoch,
          if (poll!.closed) 'closed': true,
        },
      if (card != null)
        'card': {
          'name': card!.name,
          if (card!.phone.isNotEmpty) 'phone': card!.phone,
          if (card!.username.isNotEmpty) 'username': card!.username,
        },
      if (place != null)
        'place': {
          'lat': place!.lat,
          'lng': place!.lng,
          if (place!.label.isNotEmpty) 'label': place!.label,
        },
      if (call.isNotEmpty) 'call': call,
      if (callMs > 0) 'callMs': callMs,
      if (expires != null) 'expires': expires!.millisecondsSinceEpoch,
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
      recovery: (body['recovery'] as String?)?.trim() ?? '',
    );
  }

  /// Where the server keeps accounts, from the last [directory] call:
  /// 's3', 's3-error', 'temporary', or empty when the server did not say.
  String lastStorage = '';

  static DateTime? _reportedAt;

  /// Tells the server this copy of the app was used. Chat is optional.
  /// [download] marks a save. The id is random. Failures stay quiet.
  Future<void> reportInstall({bool force = false, bool download = false}) async {
    final now = DateTime.now();
    final recent = _reportedAt;
    if (!force &&
        !download &&
        recent != null &&
        now.difference(recent) < const Duration(minutes: 2)) {
      return;
    }
    try {
      final id = await _installId();
      final platform = chatDevicePlatform();
      if (id == null || platform == null) return;
      final token = await ChatSession.token();
      final name = await appDeviceName();
      final model = await appDeviceModel();
      await _dio.post<dynamic>(
        '/api/v1/app/opened',
        data: {
          'id': id,
          'platform': platform,
          'version': AppConstants.appVersion,
          if (name.trim().isNotEmpty) 'name': name.trim(),
          if (model.trim().isNotEmpty) 'model': model.trim(),
          if (download) 'download': true,
        },
        options: Options(
          headers: {
            if (token != null && token.isNotEmpty) 'X-Chat-Token': token,
          },
        ),
      );
      _reportedAt = DateTime.now();
    } catch (_) {}
  }

  Future<ChatAdminSnapshot> directory() async {
    final response = await _dio.get<dynamic>(
      '/api/v1/chat/admin/users',
      options: await _auth(),
    );
    final body = _object(response);
    lastStorage = (body['storage'] as String?)?.trim() ?? '';
    return ChatAdminSnapshot(
      people: _directoryRows(body['users']),
      devices: _deviceRows(body['devices']),
      storage: lastStorage,
    );
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
    final groupAdmins = <String>[];
    var peerRequest = false;
    var groupAbout = '';
    var groupRules = '';
    var groupAnnounce = false;
    var groupOwner = '';
    var inviteExp = 0;
    var vanish = 0;
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
      peerRequest = peer['request'] == true;
      groupAbout = (peer['about'] as String?)?.trim() ?? '';
      groupRules = (peer['rules'] as String?)?.trim() ?? '';
      groupAnnounce = peer['announce'] == true;
      groupOwner = (peer['ownerName'] as String?)?.trim() ?? '';
      inviteExp = (peer['inviteExp'] as num?)?.toInt() ?? 0;
      vanish = (peer['vanish'] as num?)?.toInt() ?? 0;
      final admins = peer['admins'];
      if (admins is List) {
        for (final name in admins) {
          if (name is String && name.trim().isNotEmpty) {
            groupAdmins.add(name.trim());
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
      peerRequest: peerRequest,
      groupAbout: groupAbout,
      groupRules: groupRules,
      groupAnnounce: groupAnnounce,
      groupOwner: groupOwner,
      groupAdmins: groupAdmins,
      inviteExp: inviteExp,
      vanish: vanish,
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

  Future<ChatGroup> addMember(String id, String username) async {
    final handle = username.trim().replaceFirst(RegExp(r'^@'), '');
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/groups/$id/members',
      data: {'username': handle},
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
    final rawAdmins = body['admins'];
    return ChatGroup(
      id: id,
      name: name,
      code: (body['code'] as String?)?.trim() ?? '',
      members: [
        if (raw is List)
          for (final item in raw)
            if (item is String && item.trim().isNotEmpty) item.trim(),
      ],
      about: (body['about'] as String?)?.trim() ?? '',
      rules: (body['rules'] as String?)?.trim() ?? '',
      announce: body['announce'] == true,
      owner: (body['owner'] as String?)?.trim() ?? '',
      admins: [
        if (rawAdmins is List)
          for (final item in rawAdmins)
            if (item is String && item.trim().isNotEmpty) item.trim(),
      ],
      inviteExp: (body['inviteExp'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> markRead(String id, int messageId) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/threads/$id/read',
      data: {'id': messageId},
      options: await _auth(),
    );
  }

  Future<ChatMessage> sendRich(
    String id, {
    String text = '',
    int reply = 0,
    ChatPoll? poll,
    ChatCard? card,
    ChatPlace? place,
  }) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/threads/$id',
      data: {
        if (text.trim().isNotEmpty) 'text': text.trim(),
        if (reply > 0) 'reply': reply,
        if (poll != null)
          'poll': {
            'question': poll.question,
            'choices': poll.choices,
            if (poll.closes != null)
              'closes': poll.closes!.millisecondsSinceEpoch,
          },
        if (card != null)
          'card': {
            'name': card.name,
            if (card.phone.isNotEmpty) 'phone': card.phone,
            if (card.username.isNotEmpty) 'username': card.username,
          },
        if (place != null)
          'place': {
            'lat': place.lat,
            'lng': place.lng,
            if (place.label.isNotEmpty) 'label': place.label,
          },
      },
      options: await _auth(),
    );
    return _message(response, 'That message could not be sent.');
  }

  Future<void> setPrivacy({
    String? online,
    String? lastSeen,
    String? photo,
    String? receipts,
  }) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/privacy',
      data: {
        'online': ?online,
        'lastSeen': ?lastSeen,
        'photo': ?photo,
        'receipts': ?receipts,
      },
      options: await _auth(),
    );
  }

  Future<List<ChatStatusNote>> statuses() async {
    final response = await _dio.get<dynamic>(
      '/api/v1/chat/status',
      options: await _auth(),
    );
    final raw = _object(response)['statuses'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) ChatStatusNote.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  Future<void> postStatus({
    required String text,
    String audience = 'all',
    List<String> allow = const [],
    List<String> deny = const [],
  }) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/status',
      data: {
        'text': text,
        'audience': audience,
        if (allow.isNotEmpty) 'allow': allow,
        if (deny.isNotEmpty) 'deny': deny,
      },
      options: await _auth(),
    );
  }

  Future<void> markStatusView(String id) async {
    final clean = id.trim();
    if (clean.isEmpty) return;
    await _dio.post<dynamic>(
      '/api/v1/chat/status/$clean/view',
      options: await _auth(),
    );
  }

  Future<void> setGroupAdmin(String id, String username, {required bool on}) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/groups/$id/admins',
      data: {'username': username, 'on': on},
      options: await _auth(),
    );
  }

  Future<void> removeMember(String id, String username) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/groups/$id/remove',
      data: {'username': username},
      options: await _auth(),
    );
  }

  Future<void> transferGroup(String id, String username) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/groups/$id/transfer',
      data: {'username': username},
      options: await _auth(),
    );
  }

  Future<String> rotateInvite(String id, {int hours = 0}) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/groups/$id/invite',
      data: {'hours': hours},
      options: await _auth(),
    );
    return (_object(response)['code'] as String?)?.trim() ?? '';
  }

  Future<void> setGroupInfo(
    String id, {
    String? about,
    String? rules,
    bool? announce,
  }) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/groups/$id/info',
      data: {
        'about': ?about,
        'rules': ?rules,
        'announce': ?announce,
      },
      options: await _auth(),
    );
  }

  Future<ChatMessage> votePoll(
    String id,
    int messageId, {
    int? choice,
    bool close = false,
  }) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/threads/$id/poll',
      data: {
        'id': messageId,
        'choice': ?choice,
        if (close) 'close': true,
      },
      options: await _auth(),
    );
    return _message(response, 'That vote could not be saved.');
  }

  Future<void> scheduleMessage(
    String id, {
    required String text,
    required DateTime sendAt,
    int reply = 0,
  }) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/threads/$id/schedule',
      data: {
        'thread': id,
        'text': text,
        'sendAt': sendAt.toUtc().millisecondsSinceEpoch,
        'zone': DateTime.now().timeZoneName,
        if (reply > 0) 'reply': reply,
      },
      options: await _auth(),
    );
  }

  Future<void> editSchedule(
    String scheduleId, {
    required String text,
    required DateTime sendAt,
  }) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/schedules/edit',
      data: {
        'id': scheduleId,
        'text': text,
        'sendAt': sendAt.toUtc().millisecondsSinceEpoch,
        'zone': DateTime.now().timeZoneName,
      },
      options: await _auth(),
    );
  }

  Future<void> cancelSchedule(String scheduleId) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/schedules/cancel',
      data: {'id': scheduleId},
      options: await _auth(),
    );
  }

  Future<List<ChatScheduleNote>> schedules() async {
    final response = await _dio.get<dynamic>(
      '/api/v1/chat/schedules',
      options: await _auth(),
    );
    final raw = _object(response)['schedules'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map)
          ChatScheduleNote.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  Future<void> setStar(String threadId, int messageId, {required bool on}) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/stars',
      data: {'thread': threadId, 'id': messageId, 'on': on},
      options: await _auth(),
    );
  }

  Future<List<ChatStarred>> stars() async {
    final response = await _dio.get<dynamic>(
      '/api/v1/chat/stars',
      options: await _auth(),
    );
    final raw = _object(response)['stars'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) ChatStarred.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  Future<void> saveLabel({
    String id = '',
    required String name,
    List<String> threads = const [],
    bool delete = false,
  }) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/labels',
      data: {
        if (id.isNotEmpty) 'id': id,
        'name': name,
        'threads': threads,
        if (delete) 'delete': true,
      },
      options: await _auth(),
    );
  }

  Future<List<ChatFolder>> labels() async {
    final response = await _dio.get<dynamic>(
      '/api/v1/chat/labels',
      options: await _auth(),
    );
    final raw = _object(response)['labels'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) ChatFolder.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  Future<void> setTimer(String id, {int vanish = 0, int clearHours = 0}) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/threads/$id/timer',
      data: {'vanish': vanish, 'clearHours': clearHours},
      options: await _auth(),
    );
  }

  Future<void> acceptRequest(String id) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/threads/$id/accept',
      options: await _auth(),
    );
  }

  Future<void> reportUser(String username, {String reason = ''}) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/report',
      data: {
        'username': username,
        if (reason.trim().isNotEmpty) 'reason': reason.trim(),
      },
      options: await _auth(),
    );
  }

  Future<String> rotateRecovery() async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/recovery',
      options: await _auth(),
    );
    return (_object(response)['recovery'] as String?)?.trim() ?? '';
  }

  Future<ChatRegistration> recover({
    required String username,
    required String code,
    required String password,
  }) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/recover',
      data: {'username': username, 'code': code, 'password': password},
    );
    final body = _object(response);
    final token = (body['token'] as String?)?.trim() ?? '';
    final user = body['user'];
    if (token.isEmpty || user is! Map) {
      throw DioException(
        requestOptions: response.requestOptions,
        message: 'That recovery code could not be used.',
      );
    }
    return ChatRegistration(
      token: token,
      user: ChatUser.fromJson(Map<String, dynamic>.from(user)),
      recovery: (body['recovery'] as String?)?.trim() ?? '',
    );
  }

  Future<List<ChatDeviceSession>> deviceSessions() async {
    final response = await _dio.get<dynamic>(
      '/api/v1/chat/sessions',
      options: await _auth(),
    );
    final raw = _object(response)['sessions'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map)
          ChatDeviceSession.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  /// Names this signed-in device. A failure must not block opening chat.
  Future<void> touchThisDevice() async {
    try {
      final name = await appDeviceName();
      final platform = chatDevicePlatform() ?? '';
      await touchDevice(name: name, platform: platform);
    } catch (_) {}
  }

  Future<void> touchDevice({String name = '', String platform = ''}) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/sessions/touch',
      data: {
        if (name.trim().isNotEmpty) 'name': name.trim(),
        if (platform.trim().isNotEmpty) 'platform': platform.trim(),
      },
      options: await _auth(),
    );
  }

  Future<void> endDevice(String id) async {
    await _dio.post<dynamic>(
      '/api/v1/chat/sessions/end',
      data: {'id': id},
      options: await _auth(),
    );
  }

  Future<void> endOtherDevices() async {
    await _dio.post<dynamic>(
      '/api/v1/chat/sessions/others',
      options: await _auth(),
    );
  }

  Future<ChatCallRecord> startCall(String threadId, {String sdp = ''}) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/calls',
      data: {'thread': threadId, if (sdp.isNotEmpty) 'sdp': sdp},
      options: await _auth(),
    );
    return _call(response);
  }

  Future<ChatCallRecord> answerCall(
    String id, {
    required bool accept,
    String sdp = '',
  }) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/calls/$id/answer',
      data: {'accept': accept, if (sdp.isNotEmpty) 'sdp': sdp},
      options: await _auth(),
    );
    return _call(response);
  }

  Future<ChatCallRecord> endCall(String id) async {
    final response = await _dio.post<dynamic>(
      '/api/v1/chat/calls/$id/end',
      options: await _auth(),
    );
    return _call(response);
  }

  Future<List<ChatCallRecord>> calls() async {
    final response = await _dio.get<dynamic>(
      '/api/v1/chat/calls',
      options: await _auth(),
    );
    final raw = _object(response)['calls'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) ChatCallRecord.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  ChatCallRecord _call(Response<dynamic> response) {
    final raw = _object(response)['call'];
    if (raw is! Map) {
      throw DioException(
        requestOptions: response.requestOptions,
        message: 'That call could not be updated.',
      );
    }
    return ChatCallRecord.fromJson(Map<String, dynamic>.from(raw));
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
  if (error is String) {
    final text = error.toLowerCase();
    if (text.contains('sessiondescription') ||
        text.contains('set_remote_description') ||
        text.contains('setremotedescription')) {
      return 'The call offer could not be read. Ask them to call again.';
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
