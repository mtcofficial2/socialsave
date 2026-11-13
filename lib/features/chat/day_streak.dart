import 'package:shared_preferences/shared_preferences.dart';

/// A local day count. Opening chats on a new day keeps it going.
class DayMark {
  const DayMark({required this.day, required this.count});

  final String day;
  final int count;
}

String dayKey(DateTime now) {
  final local = now.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}

/// Same day keeps the count. The next day adds one. A gap starts again at 1.
DayMark bumpStreak({
  required String? lastDay,
  required int count,
  required DateTime now,
}) {
  final today = dayKey(now);
  final kept = count < 1 ? 0 : count;
  if (lastDay == today) {
    return DayMark(day: today, count: kept < 1 ? 1 : kept);
  }
  final yesterday = dayKey(now.subtract(const Duration(days: 1)));
  if (lastDay == yesterday && kept > 0) {
    return DayMark(day: today, count: kept + 1);
  }
  return DayMark(day: today, count: 1);
}

String streakLabel(int count) {
  if (count <= 0) return '';
  if (count == 1) return '1-day streak';
  return '$count-day streak';
}

/// The chat-list line under My status, including the streak when there is one.
String statusListLine({required int? views, required int streak, required String viewLabel}) {
  final base = views == null ? 'Tap to see updates' : 'Tap to see updates · $viewLabel';
  final mark = streakLabel(streak);
  if (mark.isEmpty) return base;
  return '$base · $mark';
}

class DayStreakStore {
  DayStreakStore._();

  static const _dayKey = 'chat.streak.day.v1';
  static const _countKey = 'chat.streak.count.v1';

  static Future<int> touch([DateTime? now]) async {
    final prefs = await SharedPreferences.getInstance();
    final next = bumpStreak(
      lastDay: prefs.getString(_dayKey),
      count: prefs.getInt(_countKey) ?? 0,
      now: now ?? DateTime.now(),
    );
    await prefs.setString(_dayKey, next.day);
    await prefs.setInt(_countKey, next.count);
    return next.count;
  }
}
