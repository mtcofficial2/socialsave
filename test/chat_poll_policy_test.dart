import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_alert_policy.dart';

void main() {
  final now = DateTime(2026, 11, 21, 23);

  test('without the live connection every timed check runs', () {
    expect(chatPollDue(live: false, last: now, now: now), isTrue);
  });

  test('with the live connection checks slow down to a safety net', () {
    expect(chatPollDue(live: true, last: null, now: now), isTrue);
    expect(chatPollDue(live: true, last: now.subtract(const Duration(seconds: 8)), now: now), isFalse);
    expect(chatPollDue(live: true, last: now.subtract(const Duration(seconds: 30)), now: now), isTrue);
    expect(
      chatPollDue(live: true, last: now.subtract(const Duration(seconds: 10)), now: now, liveGap: const Duration(seconds: 15)),
      isFalse,
    );
  });
}
