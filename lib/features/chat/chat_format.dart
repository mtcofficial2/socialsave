import 'package:flutter/material.dart';

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
  if (status == 'failed' || status == 'sending') return status;
  if (id <= 0) return '';
  if (peerRead >= id) return 'read';
  if (peerDelivered >= id) return 'delivered';
  if (status == 'read' || status == 'delivered' || status == 'sent') return status;
  return 'sent';
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

/// What a notification says when this chat is not the one on screen.
String chatAlertBody(String lastText) {
  final text = lastText.trim();
  if (text.isEmpty) return 'New message';
  if (text == 'Voice message') return 'Voice message';
  if (text == 'Photo') return 'Photo';
  return text;
}

String chatPreview(String lastText, String lastFrom, String me) {
  final text = lastText.trim();
  if (text.isEmpty) return 'No messages yet';
  if (lastFrom.isNotEmpty && lastFrom == me) return 'You: $text';
  return text;
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
  if (status == 'read') return const Color(0xFF53BDEB);
  return dark ? const Color(0xFFAEBAC1) : const Color(0xFF667781);
}
