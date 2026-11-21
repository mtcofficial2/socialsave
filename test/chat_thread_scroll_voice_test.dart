import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/features/chat/chat_voice.dart';

void main() {
  group('voice bar follows the player', () {
    test('uses the real audio length once the player knows it', () {
      expect(chatVoiceTotalMs(playerMs: 4380, sentMs: 5100), 4380);
      expect(chatVoiceTotalMs(playerMs: 0, sentMs: 5100), 5100);
      expect(chatVoiceTotalMs(playerMs: 0, sentMs: 0), 0);
    });

    test('the bar is full exactly when the sound ends, not before or after', () {
      // The old code measured against the recorded 5.1 s while the file was
      // 4.38 s long, so the sound ended with the bar at 86%.
      expect(chatVoiceProgress(positionMs: 4380, totalMs: 5100), closeTo(0.859, 0.001));
      expect(chatVoiceProgress(positionMs: 4380, totalMs: 4380), 1.0);
      expect(chatVoiceProgress(positionMs: 2190, totalMs: 4380), 0.5);
      expect(chatVoiceProgress(positionMs: 9000, totalMs: 4380), 1.0);
      expect(chatVoiceProgress(positionMs: 0, totalMs: 4380), 0);
      expect(chatVoiceProgress(positionMs: 100, totalMs: 0), 0);
    });

    test('the clock counts down while playing and shows the length otherwise', () {
      expect(chatVoiceClockMs(positionMs: 1000, totalMs: 4380, active: true), 3380);
      expect(chatVoiceClockMs(positionMs: 5000, totalMs: 4380, active: true), 0);
      expect(chatVoiceClockMs(positionMs: 0, totalMs: 4380, active: false), 4380);
    });
  });

  group('chat opens light at the newest message', () {
    test('older messages are added a page at a time', () {
      expect(chatThreadNextWindow(60, 500), 110);
      expect(chatThreadNextWindow(480, 500), 500);
    });

    test('jumping to an old message loads its page with context above it', () {
      expect(chatThreadWindowFor(100, 500, 60), 410);
      expect(chatThreadWindowFor(480, 500, 60), 60);
      expect(chatThreadWindowFor(0, 500, 60), 500);
      expect(chatThreadWindowFor(-1, 500, 60), 60);
    });

    test('reversed list guesses the offset from the bottom', () {
      expect(chatReversedOffsetGuess(row: 99, rows: 100, maxExtent: 9900), 0);
      expect(chatReversedOffsetGuess(row: 0, rows: 100, maxExtent: 9900), 9900);
      expect(chatReversedOffsetGuess(row: 49, rows: 99, maxExtent: 9800), closeTo(4900, 0.1));
      expect(chatReversedOffsetGuess(row: 0, rows: 1, maxExtent: 100), 0);
    });
  });
}
