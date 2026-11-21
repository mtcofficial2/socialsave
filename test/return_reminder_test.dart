import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/reminders/return_reminder.dart';

void main() {
  test('first reminder is six hours after an open, in the daytime', () {
    final open = DateTime(2026, 6, 2, 10, 0);
    final at = returnReminderAt(lastOpen: open, now: open);
    expect(at, DateTime(2026, 6, 2, 16, 0));
    expect(returnReminderQuiet(at), isFalse);
  });

  test('a late evening open waits until the next morning', () {
    final open = DateTime(2026, 6, 2, 18, 0);
    final at = returnReminderAt(lastOpen: open, now: open);
    expect(at, DateTime(2026, 6, 3, 8, 15));
  });

  test('an open just before midnight lands at 08:15', () {
    final open = DateTime(2026, 6, 2, 23, 0);
    final at = returnReminderAt(lastOpen: open, now: open);
    expect(at, DateTime(2026, 6, 3, 8, 15));
  });

  test('a long gap reminds a minute from now, or at 08:15 if that is night', () {
    final open = DateTime(2026, 6, 1, 10, 0);
    final afternoon = DateTime(2026, 6, 4, 15, 30);
    expect(
      returnReminderAt(lastOpen: open, now: afternoon),
      DateTime(2026, 6, 4, 15, 31),
    );
    final night = DateTime(2026, 6, 4, 23, 30);
    expect(
      returnReminderAt(lastOpen: open, now: night),
      DateTime(2026, 6, 5, 8, 15),
    );
    final early = DateTime(2026, 6, 4, 7, 0);
    expect(
      returnReminderAt(lastOpen: open, now: early),
      DateTime(2026, 6, 4, 8, 15),
    );
  });

  test('the sentence follows the day and stays on the known lines', () {
    expect(returnReminderDayIndex(DateTime(2026, 1, 1)), 0);
    expect(returnReminderDayIndex(DateTime(2026, 1, 2)), 1);
    final line = returnReminderMessage(DateTime(2026, 1, 1, 9));
    expect(returnReminderLines, contains(line));
    expect(line, returnReminderLines.first);
    expect(returnReminderTitle, 'Open SocialSave');
  });
}
