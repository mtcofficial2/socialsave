import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/notifications/notification_service.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/core/diagnostics/quiet_log.dart';

/// How long Social Save can sit closed before the phone asks the owner back.
const returnReminderGap = Duration(hours: 6);

/// Quiet window, local time. 22:00 inclusive through 08:00 exclusive.
const returnReminderQuietStart = 22;
const returnReminderQuietEnd = 8;
const returnReminderMorningMinute = 15;

/// Keep these sentences in step with [ReturnReminder] in ReturnReminder.kt.
const returnReminderLines = <String>[
  'SocialSave is still here. Open it to save a video or check your chats.',
  'You have not opened SocialSave in a while. Your library is waiting.',
  'Open SocialSave so it stays easy to find on this phone.',
  'A quick visit keeps SocialSave close. Paste a link or open a chat.',
];

const returnReminderTitle = 'Open SocialSave';

/// Day of the year starting at 0, so 1 January is 0.
int returnReminderDayIndex(DateTime at) {
  final start = DateTime.utc(at.year, 1, 1);
  final here = DateTime.utc(at.year, at.month, at.day);
  return here.difference(start).inDays;
}

String returnReminderMessage(DateTime at) {
  final index = returnReminderDayIndex(at) % returnReminderLines.length;
  return returnReminderLines[index];
}

bool returnReminderQuiet(DateTime at) {
  return at.hour >= returnReminderQuietStart || at.hour < returnReminderQuietEnd;
}

/// Moves [at] to 08:15 when it falls in the quiet window.
DateTime returnReminderAwake(DateTime at) {
  if (!returnReminderQuiet(at)) return at;
  if (at.hour >= returnReminderQuietStart) {
    final next = DateTime(at.year, at.month, at.day).add(const Duration(days: 1));
    return DateTime(
      next.year,
      next.month,
      next.day,
      returnReminderQuietEnd,
      returnReminderMorningMinute,
    );
  }
  return DateTime(at.year, at.month, at.day, returnReminderQuietEnd, returnReminderMorningMinute);
}

/// Next reminder for someone who last opened the app at [lastOpen].
///
/// The first one is [gap] after that open. If that moment has already passed,
/// the next one is a minute from [now]. Either way it stays outside 22:00–08:00.
DateTime returnReminderAt({
  required DateTime lastOpen,
  required DateTime now,
  Duration gap = returnReminderGap,
}) {
  var at = lastOpen.add(gap);
  if (!at.isAfter(now)) at = now.add(const Duration(minutes: 1));
  return returnReminderAwake(at);
}

const _openedKey = 'socialsave_lastOpenMs';
const _askedKey = 'socialsave_returnRemindAsked';

/// Records this open and arms, or cancels, the Android reminder.
///
/// Windows, web, and tests on this PC do nothing. The phone alarm still
/// fires after the process is gone; opening the app starts the six hours over.
class ReturnReminder {
  static const channel = MethodChannel('socialsave/return_reminder');

  static Future<void> touch({required bool enabled}) async {
    if (kIsWeb || !Plat.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    await prefs.setInt(_openedKey, now.millisecondsSinceEpoch);
    if (enabled && prefs.getBool(_askedKey) != true) {
      await prefs.setBool(_askedKey, true);
      try {
        await NotificationService().requestPermission();
      } catch (e) { logQuiet('return_reminder', e); }
    }
    try {
      if (!enabled) {
        await channel.invokeMethod<void>('cancel');
        return;
      }
      final at = returnReminderAt(lastOpen: now, now: now);
      await channel.invokeMethod<void>('schedule', <String, Object>{
        'at': at.millisecondsSinceEpoch,
      });
    } catch (e) { logQuiet('return_reminder', e); }
  }
}
