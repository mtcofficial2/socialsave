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

/// Tick for one of your messages: sent, delivered, or read.
String chatTick({
  required bool mine,
  required int id,
  required int peerDelivered,
  required int peerRead,
  String status = '',
}) {
  if (!mine || id <= 0) return '';
  if (peerRead >= id) return 'read';
  if (peerDelivered >= id) return 'delivered';
  if (status == 'read' || status == 'delivered' || status == 'sent') return status;
  return 'sent';
}

String chatPreview(String lastText, String lastFrom, String me) {
  final text = lastText.trim();
  if (text.isEmpty) return 'No messages yet';
  if (lastFrom.isNotEmpty && lastFrom == me) return 'You: $text';
  return text;
}
