import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:social_save/features/chat/chat_api.dart';

/// Conversations kept on this phone so they open with no data and no Wi-Fi.
///
/// The server still holds only the latest 200 messages. This phone keeps what
/// it has already seen, up to 2000 per chat, including messages that were
/// still waiting to send.
class ChatLog {
  const ChatLog({
    required this.messages,
    this.delivered = 0,
    this.read = 0,
    this.seen,
    this.photoRev = 0,
  });

  final List<ChatMessage> messages;
  final int delivered;
  final int read;
  final DateTime? seen;
  final int photoRev;

  int get newest {
    var id = 0;
    for (final message in messages) {
      if (message.id > id) id = message.id;
    }
    return id;
  }
}

class ChatHistory {
  static const keep = 2000;

  @visibleForTesting
  static Directory? rootOverride;

  static final Map<String, _Book> _open = {};
  static Future<void> _tail = Future<void>.value();
  static Future<void>? _archive;

  @visibleForTesting
  static void debugReset() {
    _open.clear();
    _archive = null;
  }

  static Future<List<ChatThreadSummary>> threads(String username) {
    return _run(() async {
      final book = await _book(username);
      if (book == null) return const [];
      return [
        for (final item in book.threads) item.copyWith(online: false),
      ];
    });
  }

  static Future<void> saveThreads(
    String username,
    List<ChatThreadSummary> items,
  ) {
    return _run(() async {
      final book = await _book(username);
      if (book == null) return;
      book.mergeThreads(items);
      await book.flush();
    });
  }

  static Future<ChatLog?> log(String username, String threadId) {
    return _run(() async {
      final book = await _book(username);
      if (book == null || !_threadOk(threadId)) return null;
      final found = book.logs[threadId];
      if (found == null) return null;
      return found;
    });
  }

  static Future<int> newest(String username, String threadId) async {
    final found = await log(username, threadId);
    return found?.newest ?? 0;
  }

  /// The open conversation is the source for messages still waiting to send.
  static Future<void> saveLog({
    required String username,
    required String threadId,
    required List<ChatMessage> messages,
    required int delivered,
    required int read,
    DateTime? seen,
    required int photoRev,
  }) {
    return _run(() async {
      final book = await _book(username);
      if (book == null || !_threadOk(threadId)) return;
      final prior = book.logs[threadId];
      final merged = _union(prior?.messages ?? const [], messages);
      book.logs[threadId] = ChatLog(
        messages: _cap(merged),
        delivered: _max(prior?.delivered ?? 0, delivered),
        read: _max(prior?.read ?? 0, read),
        seen: _later(prior?.seen, seen),
        photoRev: _max(prior?.photoRev ?? 0, photoRev),
      );
      await book.flush();
    });
  }

  /// A live message, saved even when that chat is not on screen.
  static Future<void> remember({
    required String me,
    required String threadId,
    required ChatMessage message,
    bool open = false,
  }) {
    return _run(() async {
      final book = await _book(me);
      if (book == null || !_threadOk(threadId) || message.id <= 0) return;
      final prior = book.logs[threadId];
      final merged = _addIncoming(prior?.messages ?? const [], [message]);
      book.logs[threadId] = ChatLog(
        messages: _cap(merged),
        delivered: prior?.delivered ?? 0,
        read: prior?.read ?? 0,
        seen: prior?.seen,
        photoRev: prior?.photoRev ?? 0,
      );
      book.notePreview(me: me, threadId: threadId, message: message, open: open);
      await book.flush();
    });
  }

  static Future<void> merge({
    required String username,
    required String threadId,
    required List<ChatMessage> incoming,
    int delivered = 0,
    int read = 0,
    DateTime? seen,
    int photoRev = 0,
  }) {
    return _run(() async {
      final book = await _book(username);
      if (book == null || !_threadOk(threadId)) return;
      final prior = book.logs[threadId];
      book.logs[threadId] = ChatLog(
        messages: _cap(_addIncoming(prior?.messages ?? const [], incoming)),
        delivered: _max(prior?.delivered ?? 0, delivered),
        read: _max(prior?.read ?? 0, read),
        seen: _later(prior?.seen, seen),
        photoRev: _max(prior?.photoRev ?? 0, photoRev),
      );
      await book.flush();
    });
  }

  /// Pulls any messages this phone has not stored yet. One chat at a time.
  static Future<void> archiveInbox(
    ChatApi api,
    String username,
    List<ChatThreadSummary> items,
  ) {
    final running = _archive;
    if (running != null) return running;
    final job = _archiveInbox(api, username, items);
    _archive = job;
    return job.whenComplete(() {
      if (identical(_archive, job)) _archive = null;
    });
  }

  static Future<void> _archiveInbox(
    ChatApi api,
    String username,
    List<ChatThreadSummary> items,
  ) async {
    await saveThreads(username, items);
    for (final item in items) {
      if (!_threadOk(item.id) || item.lastId <= 0) continue;
      final known = await newest(username, item.id);
      if (known >= item.lastId) continue;
      try {
        final sync = await api.messages(item.id, known);
        await merge(
          username: username,
          threadId: item.id,
          incoming: sync.messages,
          delivered: sync.peerDelivered,
          read: sync.peerRead,
          seen: sync.peerLastSeen,
          photoRev: sync.peerPhotoRev,
        );
      } catch (_) {
        return;
      }
    }
  }

  static Future<T> _run<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then((_) {}, onError: (_) {});
    return next;
  }

  static Future<_Book?> _book(String username) async {
    final name = _name(username);
    if (name == null) return null;
    final cached = _open[name];
    if (cached != null) return cached;
    final book = _Book(name);
    await book.load();
    _open[name] = book;
    return book;
  }

  static String? _name(String username) {
    final name = username.trim().toLowerCase().replaceFirst(RegExp(r'^@'), '');
    if (!RegExp(r'^[a-z0-9_]{1,32}$').hasMatch(name)) return null;
    return name;
  }

  static bool _threadOk(String id) => RegExp(r'^[a-z0-9]{1,40}$').hasMatch(id);

  static int _max(int a, int b) => a > b ? a : b;

  static DateTime? _later(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  static List<ChatMessage> _cap(List<ChatMessage> messages) {
    final pending = [for (final item in messages) if (item.id < 0) item];
    final saved = [for (final item in messages) if (item.id >= 0) item]
      ..sort((a, b) => a.id.compareTo(b.id));
    final start = saved.length > keep ? saved.length - keep : 0;
    return [...saved.sublist(start), ...pending];
  }

  static List<ChatMessage> _union(
    List<ChatMessage> disk,
    List<ChatMessage> widget,
  ) {
    final widgetIds = {for (final item in widget) item.id};
    final byId = <int, ChatMessage>{};
    for (final item in disk) {
      if (item.id < 0 && !widgetIds.contains(item.id)) continue;
      byId[item.id] = item;
    }
    for (final item in widget) {
      byId[item.id] = item;
    }
    final pending = [for (final item in widget) if (item.id < 0) item];
    final saved = byId.values.where((item) => item.id >= 0).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return [...saved, ...pending];
  }

  static List<ChatMessage> _addIncoming(
    List<ChatMessage> current,
    List<ChatMessage> incoming,
  ) {
    final next = [...current];
    for (final server in incoming) {
      if (server.id <= 0) continue;
      next.removeWhere((local) => _samePending(local, server));
      final index = next.indexWhere((item) => item.id == server.id);
      if (index >= 0) {
        next[index] = server.withQuoteFrom(next[index]);
      } else {
        next.add(server);
      }
    }
    return next;
  }

  static bool _samePending(ChatMessage local, ChatMessage server) {
    if (local.id >= 0 || local.name != server.name) return false;
    if (local.pendingKind == 'voice') {
      return server.isVoice && server.voiceMs == local.voiceMs;
    }
    if (local.pendingKind == 'photo') {
      return server.isPhoto && local.text == server.text;
    }
    if (local.pendingKind.isNotEmpty) return false;
    return !server.isVoice && !server.isPhoto && local.text == server.text;
  }
}

class _Book {
  _Book(this.name);

  final String name;
  final List<ChatThreadSummary> threads = [];
  final Map<String, ChatLog> logs = {};

  Future<void> load() async {
    final file = await _file();
    if (!await file.exists()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      final rawThreads = decoded['threads'];
      if (rawThreads is List) {
        for (final item in rawThreads) {
          if (item is! Map) continue;
          final thread = ChatThreadSummary.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (!ChatHistory._threadOk(thread.id)) continue;
          threads.add(thread.copyWith(online: false));
        }
      }
      final rawLogs = decoded['logs'];
      if (rawLogs is Map) {
        for (final entry in rawLogs.entries) {
          final id = entry.key;
          final body = entry.value;
          if (id is! String || body is! Map || !ChatHistory._threadOk(id)) {
            continue;
          }
          logs[id] = await _logFromJson(Map<String, dynamic>.from(body));
        }
      }
    } catch (_) {}
  }

  Future<void> flush() async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final payload = jsonEncode({
      'threads': [for (final item in threads) item.toJson()],
      'logs': {
        for (final entry in logs.entries) entry.key: _logToJson(entry.value),
      },
    });
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(payload, flush: true);
    try {
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    } catch (_) {
      await file.writeAsString(payload, flush: true);
      if (await tmp.exists()) await tmp.delete();
    }
    await _syncPending();
  }

  void mergeThreads(List<ChatThreadSummary> items) {
    final disk = {for (final item in threads) item.id: item};
    final seen = <String>{};
    final next = <ChatThreadSummary>[];
    for (final item in items) {
      if (!ChatHistory._threadOk(item.id) || !seen.add(item.id)) continue;
      next.add(_prefer(disk[item.id], item));
    }
    for (final item in threads) {
      if (seen.contains(item.id)) continue;
      next.add(item.copyWith(online: false));
    }
    threads
      ..clear()
      ..addAll(next);
  }

  void notePreview({
    required String me,
    required String threadId,
    required ChatMessage message,
    required bool open,
  }) {
    final mine = me.isNotEmpty && message.name == me;
    ChatThreadSummary? current;
    for (final item in threads) {
      if (item.id == threadId) current = item;
    }
    if (current != null && message.id <= current.lastId) return;
    final username = current?.username ?? (mine ? '' : message.name);
    if (username.isEmpty) return;
    final row = ChatThreadSummary(
      id: threadId,
      username: username,
      lastText: message.text,
      lastAt: message.at,
      lastId: message.id,
      lastFrom: message.name,
      lastStatus: message.status.isEmpty
          ? (current?.lastStatus ?? '')
          : message.status,
      unread: mine || open ? (current?.unread ?? 0) : (current?.unread ?? 0) + 1,
      lastSeen: current?.lastSeen,
      photoRev: current?.photoRev ?? 0,
    );
    threads.removeWhere((item) => item.id == threadId);
    threads.insert(0, row);
  }

  ChatThreadSummary _prefer(ChatThreadSummary? disk, ChatThreadSummary incoming) {
    final quiet = incoming.copyWith(online: false);
    if (disk == null) return quiet;
    if (incoming.lastId > disk.lastId) return quiet;
    if (incoming.lastId < disk.lastId) return disk.copyWith(online: false);
    final unread = incoming.unread < disk.unread ? incoming.unread : disk.unread;
    final seen = ChatHistory._later(disk.lastSeen, incoming.lastSeen);
    return quiet.copyWith(
      unread: unread,
      lastSeen: seen,
      photoRev: ChatHistory._max(disk.photoRev, incoming.photoRev),
    );
  }

  Future<ChatLog> _logFromJson(Map<String, dynamic> json) async {
    final raw = json['messages'];
    final messages = <ChatMessage>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        var message = ChatMessage.fromJson(Map<String, dynamic>.from(item));
        if (message.id < 0 && message.status == 'sending') {
          message = message.copyWith(status: 'failed');
        }
        if (message.id < 0) {
          final bytes = await _pendingBytes(message.id);
          if (bytes != null) {
            message = ChatMessage(
              id: message.id,
              from: message.from,
              name: message.name,
              text: message.text,
              links: message.links,
              at: message.at,
              status: message.status,
              voice: message.voice,
              voiceMs: message.voiceMs,
              voiceType: message.voiceType,
              reply: message.reply,
              replyName: message.replyName,
              replyText: message.replyText,
              photo: message.photo,
              photoType: message.photoType,
              localBytes: bytes,
              pendingKind: message.pendingKind,
            );
          }
        }
        messages.add(message);
      }
    }
    final seenAt = (json['seen'] as num?)?.toInt() ?? 0;
    return ChatLog(
      messages: messages,
      delivered: (json['delivered'] as num?)?.toInt() ?? 0,
      read: (json['read'] as num?)?.toInt() ?? 0,
      seen: seenAt > 0 ? DateTime.fromMillisecondsSinceEpoch(seenAt) : null,
      photoRev: (json['photo'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> _logToJson(ChatLog log) {
    return {
      'delivered': log.delivered,
      'read': log.read,
      'seen': log.seen?.millisecondsSinceEpoch ?? 0,
      'photo': log.photoRev,
      'messages': [for (final item in log.messages) item.toJson()],
    };
  }

  Future<void> _syncPending() async {
    final dir = await _pendingDir();
    final keep = <String>{};
    for (final log in logs.values) {
      for (final message in log.messages) {
        if (message.id >= 0) continue;
        final bytes = message.localBytes;
        if (bytes == null || bytes.isEmpty) continue;
        keep.add(_pendingName(message.id));
        final file = File(p.join(dir.path, _pendingName(message.id)));
        if (await file.exists() && await file.length() == bytes.length) {
          continue;
        }
        await dir.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
      }
    }
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final base = p.basename(entity.path);
      if (!base.startsWith('p')) continue;
      if (!keep.contains(base)) await entity.delete();
    }
  }

  Future<Uint8List?> _pendingBytes(int id) async {
    final file = File(p.join((await _pendingDir()).path, _pendingName(id)));
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    return bytes;
  }

  String _pendingName(int id) => 'p${id.abs()}';

  Future<Directory> _pendingDir() async {
    final root = await _root();
    return Directory(p.join(root.path, 'chat-history', name));
  }

  Future<File> _file() async {
    final root = await _root();
    return File(p.join(root.path, 'chat-history', '$name.json'));
  }

  Future<Directory> _root() async {
    final override = ChatHistory.rootOverride;
    if (override != null) return override;
    return getApplicationDocumentsDirectory();
  }
}
