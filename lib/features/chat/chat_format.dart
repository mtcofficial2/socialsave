import 'package:flutter/material.dart';
import 'package:social_save/features/chat/chat_ui.dart';
import 'package:social_save/features/chat/chat_api.dart';

enum ChatDay { today, yesterday, older }

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

const List<Color> chatAvatarPalette = [
  Color(0xFF1F6F5B),
  Color(0xFF1A365D),
  Color(0xFF6C3483),
  Color(0xFF922B21),
  Color(0xFFB9770E),
  Color(0xFF1A5276),
  Color(0xFF117A65),
  Color(0xFF5B2C6F),
];

DateTime _day(DateTime value) {
  final local = value.toLocal();
  return DateTime(local.year, local.month, local.day);
}

ChatDay chatDay(DateTime at, DateTime now) {
  final day = _day(at);
  final today = _day(now);
  if (day == today) return ChatDay.today;
  if (day == today.subtract(const Duration(days: 1))) return ChatDay.yesterday;
  return ChatDay.older;
}

/// Centered chip in a conversation.
String chatDayLabel(DateTime at, DateTime now) {
  final local = at.toLocal();
  switch (chatDay(at, now)) {
    case ChatDay.today:
      return 'Today';
    case ChatDay.yesterday:
      return 'Yesterday';
    case ChatDay.older:
      return '${local.day} ${_months[local.month - 1]} ${local.year}';
  }
}

/// Right-hand stamp on a chat row. [clock] is today's time, already formatted.
String chatListStamp(DateTime at, DateTime now, String clock) {
  final local = at.toLocal();
  switch (chatDay(at, now)) {
    case ChatDay.today:
      return clock;
    case ChatDay.yesterday:
      return 'Yesterday';
    case ChatDay.older:
      return '${local.day} ${_months[local.month - 1]}';
  }
}

String chatInitial(String username) {
  final name = username.replaceFirst(RegExp(r'^@'), '').trim();
  if (name.isEmpty) return '?';
  return name.characters.first.toUpperCase();
}

Color chatAvatarColor(String username) {
  final name = username.replaceFirst(RegExp(r'^@'), '').trim().toLowerCase();
  var hash = 0;
  for (final unit in name.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return chatAvatarPalette[hash % chatAvatarPalette.length];
}

bool chatThreadUnread({
  required String lastFrom,
  required int lastId,
  required String me,
  required int seenId,
}) {
  if (lastId <= 0 || me.isEmpty) return false;
  if (lastFrom == me) return false;
  return lastId > seenId;
}

/// Tick for one of your messages: sending, failed, sent, delivered, or read.
String chatTick({
  required bool mine,
  required int id,
  required int peerDelivered,
  required int peerRead,
  String status = '',
}) {
  if (!mine) return '';
  if (status == 'failed' || status == 'sending' || status == 'queued') return status;
  if (id <= 0) return '';
  if (peerRead >= id) return 'read';
  if (peerDelivered >= id) return 'delivered';
  if (status == 'read' || status == 'delivered' || status == 'sent') return status;
  return 'sent';
}

/// What a screen reader says before a message's own text: who sent it, what
/// kind it is, when, and (for your messages) whether it was delivered.
String chatBubbleSemantics({
  required bool mine,
  required String sender,
  required String time,
  String tick = '',
  bool voice = false,
  int voiceMs = 0,
  bool photo = false,
  bool file = false,
  bool song = false,
  bool poll = false,
  bool edited = false,
}) {
  final parts = <String>[mine ? 'You' : (sender.trim().isEmpty ? 'Message' : sender.trim())];
  if (voice) {
    final seconds = (voiceMs / 1000).round();
    parts.add(seconds > 0 ? 'voice note, $seconds seconds' : 'voice note');
  } else if (photo) {
    parts.add('photo');
  } else if (song) {
    parts.add('song');
  } else if (file) {
    parts.add('file');
  } else if (poll) {
    parts.add('poll');
  }
  if (time.isNotEmpty) parts.add(time);
  if (edited) parts.add('edited');
  switch (tick) {
    case 'sending':
      parts.add('sending');
    case 'failed':
      parts.add('not sent, tap to retry');
    case 'queued':
      parts.add('waiting for network');
    case 'sent':
      parts.add('sent');
    case 'delivered':
      parts.add('delivered');
    case 'read':
      parts.add('read');
  }
  return parts.join(', ');
}

/// Queued (offline) messages in the order they were written.
List<ChatMessage> chatResendOrder(List<ChatMessage> messages) {
  final queued = [
    for (final message in messages)
      if (message.id < 0 && message.status == 'queued') message,
  ];
  queued.sort((a, b) {
    final byTime = a.at.compareTo(b.at);
    return byTime != 0 ? byTime : b.id.compareTo(a.id);
  });
  return queued;
}

/// Whether the server already has [local] (a send that got through just as
/// the connection dropped): one of my server messages with the same content,
/// written within two minutes of it.
bool chatAlreadyDelivered(ChatMessage local, List<ChatMessage> messages, {required String me}) {
  if (me.isEmpty) return false;
  for (final item in messages) {
    if (item.id <= 0 || item.name != me) continue;
    if (item.at.difference(local.at).inSeconds.abs() > 120) continue;
    final kind = local.pendingKind;
    if (kind == 'voice') {
      if (item.isVoice && (item.voiceMs - local.voiceMs).abs() < 1500) return true;
    } else if (kind == 'photo') {
      if (item.isPhoto && item.text.trim() == local.text.trim()) return true;
    } else if (kind == 'song') {
      if (item.isSong && item.songName == local.songName) return true;
    } else if (kind == 'file' || kind == 'clip') {
      if (item.isFile && item.fileName == local.fileName) return true;
    } else if (!item.isVoice && !item.isPhoto && !item.isFile && !item.isSong) {
      if (item.text.trim() == local.text.trim()) return true;
    }
  }
  return false;
}

/// The line quoted above a reply. Voice and photo keep a short label.
String chatQuoteLabel(String text, {required bool voice, required bool photo}) {
  if (voice) return 'Voice message';
  var label = text.trim();
  if (photo && (label.isEmpty || label == 'Photo')) return 'Photo';
  final runes = label.runes;
  if (runes.length <= 80) return label;
  return String.fromCharCodes(runes.take(80));
}

/// A status reply stored as plain text. The live server cannot keep a quote.
class StatusReplyParts {
  const StatusReplyParts({
    required this.snippet,
    required this.reply,
    this.id = '',
    this.photo = false,
  });

  final String snippet;
  final String reply;

  /// Status to open when the quote is tapped. Blank on older replies.
  final String id;

  /// The status is a photo, so the quote can show that picture.
  final bool photo;
}

final _statusReplyLine = RegExp(r'^Status(?:#([a-z0-9]+)(\|photo)?)?: (.*)$');

/// Null when [text] is an ordinary message.
StatusReplyParts? parseStatusReply(String text) {
  final split = text.indexOf('\n');
  final first = split < 0 ? text : text.substring(0, split);
  final match = _statusReplyLine.firstMatch(first);
  if (match == null) return null;
  final snippet = (match.group(3) ?? '').trim();
  if (snippet.isEmpty) return null;
  final reply = split < 0 ? '' : text.substring(split + 1).trim();
  return StatusReplyParts(
    snippet: snippet,
    reply: reply,
    id: match.group(1) ?? '',
    photo: match.group(2) != null,
  );
}

/// The words a person wrote, without the status line above them.
String statusReplyShown(String text) {
  final parts = parseStatusReply(text);
  if (parts == null) return text.trim();
  if (parts.reply.isNotEmpty) return parts.reply;
  return parts.snippet;
}

/// What a notification says when this chat is not the one on screen.
String chatAlertBody(String lastText) {
  final text = lastText.trim();
  if (text.isEmpty) return 'New message';
  final status = parseStatusReply(text);
  if (status != null) {
    if (status.reply.isNotEmpty) return status.reply;
    return 'Replied to a status';
  }
  if (text == 'Voice message') return 'Voice message';
  if (text == 'Photo') return 'Photo';
  return text;
}

String chatPreview(String lastText, String lastFrom, String me) {
  final text = lastText.trim();
  if (text.isEmpty) return 'No messages yet';
  final shown = statusReplyShown(text);
  if (lastFrom.isNotEmpty && lastFrom == me) return 'You: $shown';
  return shown;
}

/// Empty when [lastSeen] is missing. Online only when the server said so.
String chatPresenceLabel(DateTime? lastSeen, bool online, DateTime now, String clock) {
  if (lastSeen == null) return '';
  if (online) return 'online';
  switch (chatDay(lastSeen, now)) {
    case ChatDay.today:
      return 'last seen today at $clock';
    case ChatDay.yesterday:
      return 'last seen yesterday';
    case ChatDay.older:
      final local = lastSeen.toLocal();
      return 'last seen ${local.day} ${_months[local.month - 1]}';
  }
}

String chatClock(int milliseconds) {
  final total = milliseconds < 0 ? 0 : milliseconds ~/ 1000;
  final minutes = total ~/ 60;
  final seconds = total % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// Sent and delivered stay gray. Read is blue. No washed-out alpha.
Color chatTickColor(String status, {required bool dark}) {
  if (status == 'read') return ChatUiTokens.linkDark;
  return ChatUiTokens.time(dark);
}

/// One slice of a message or status. A link and a username are never both set.
class ChatTextPiece {
  const ChatTextPiece({required this.text, this.link, this.username});

  final String text;

  /// Exact address to open. The visible [text] is that address.
  final String? link;

  /// Lowercase username, without @. The visible [text] keeps the written @name.
  final String? username;

  bool get isLink => link != null && link!.isNotEmpty;
  bool get isUsername => username != null && username!.isNotEmpty;
}

final _linkOrName = RegExp(
  r'https?://\S+|@([A-Za-z0-9_]{3,20})(?![A-Za-z0-9_])',
  caseSensitive: false,
);

bool _isNameChar(int unit) {
  return (unit >= 0x30 && unit <= 0x39) ||
      (unit >= 0x41 && unit <= 0x5a) ||
      (unit >= 0x61 && unit <= 0x7a) ||
      unit == 0x5f;
}

String _trimUrlTail(String raw) {
  var end = raw.length;
  while (end > 0) {
    final ch = raw[end - 1];
    if (ch == '.' || ch == ',' || ch == ')' || ch == ']') {
      end--;
      continue;
    }
    break;
  }
  return raw.substring(0, end);
}

void _pushPiece(List<ChatTextPiece> out, ChatTextPiece piece) {
  if (piece.text.isEmpty) return;
  if (out.isNotEmpty && !out.last.isLink && !out.last.isUsername && !piece.isLink && !piece.isUsername) {
    final prev = out.removeLast();
    out.add(ChatTextPiece(text: prev.text + piece.text));
    return;
  }
  out.add(piece);
}

/// Plain words, with web addresses left whole so an @ inside them is not a name.
List<ChatTextPiece> _plainPieces(String text) {
  final pieces = <ChatTextPiece>[];
  var cursor = 0;
  for (final match in _linkOrName.allMatches(text)) {
    final raw = match.group(0)!;
    final lower = raw.toLowerCase();
    final isUrl = lower.startsWith('http://') || lower.startsWith('https://');
    if (isUrl) {
      final shown = _trimUrlTail(raw);
      if (match.start > cursor) {
        _pushPiece(pieces, ChatTextPiece(text: text.substring(cursor, match.start)));
      }
      if (shown.isNotEmpty) _pushPiece(pieces, ChatTextPiece(text: shown));
      cursor = match.start + shown.length;
      continue;
    }
    final name = match.group(1);
    if (name == null) continue;
    if (match.start > 0 && _isNameChar(text.codeUnitAt(match.start - 1))) continue;
    if (match.start > cursor) {
      _pushPiece(pieces, ChatTextPiece(text: text.substring(cursor, match.start)));
    }
    _pushPiece(pieces, ChatTextPiece(text: raw, username: name.toLowerCase()));
    cursor = match.end;
  }
  if (cursor < text.length) {
    _pushPiece(pieces, ChatTextPiece(text: text.substring(cursor)));
  }
  return pieces;
}

/// Splits [text] into words, known [links], and @usernames.
///
/// A username is @ plus 3 to 20 letters, numbers, or underscores. It is not
/// taken from an email or from inside a web address. The stored username is
/// lowercase and has no @.
List<ChatTextPiece> chatTextPieces(String text, [List<String> links = const []]) {
  if (text.isEmpty) return const [ChatTextPiece(text: '')];
  final out = <ChatTextPiece>[];
  var cursor = 0;
  for (final link in links) {
    if (link.isEmpty) continue;
    final at = text.indexOf(link, cursor);
    if (at < 0) continue;
    if (at > cursor) {
      for (final piece in _plainPieces(text.substring(cursor, at))) {
        _pushPiece(out, piece);
      }
    }
    _pushPiece(out, ChatTextPiece(text: link, link: link));
    cursor = at + link.length;
  }
  if (cursor < text.length) {
    for (final piece in _plainPieces(text.substring(cursor))) {
      _pushPiece(out, piece);
    }
  }
  if (out.isEmpty) return [ChatTextPiece(text: text)];
  return out;
}

/// Short line above a status reply. A photo with no words says Photo.
String statusReplySnippet(String text, {required bool photo}) {
  final label = text.trim();
  if (photo && label.isEmpty) return 'Photo';
  if (label.isEmpty) return 'Update';
  final runes = label.runes;
  if (runes.length <= 80) return label;
  return String.fromCharCodes(runes.take(80));
}

/// What the other person reads. The live server cannot store a status as a quote.
String statusReplyBody(String snippet, String typed, {String id = '', bool photo = false}) {
  final line = snippet.trim();
  final body = typed.trim();
  if (line.isEmpty) return body;
  final cleanId = id.trim().toLowerCase();
  final head = cleanId.isEmpty
      ? 'Status: $line'
      : 'Status#$cleanId${photo ? '|photo' : ''}: $line';
  if (body.isEmpty) return head;
  return '$head\n$body';
}
