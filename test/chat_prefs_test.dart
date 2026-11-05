import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_prefs.dart';

void main() {
  test('keyboard sends until the person turns it off', () {
    expect(ChatPrefs.keyboardSendsValue(null), isTrue);
    expect(ChatPrefs.keyboardSendsValue(true), isTrue);
    expect(ChatPrefs.keyboardSendsValue(false), isFalse);
  });

  test('a computer uses the Enter key and a phone uses the Send key', () {
    expect(
      ChatPrefs.hardwareEnterSends(
        keyboardSends: true,
        platform: TargetPlatform.windows,
      ),
      isTrue,
    );
    expect(
      ChatPrefs.imeSends(
        keyboardSends: true,
        platform: TargetPlatform.windows,
      ),
      isFalse,
    );
    expect(
      ChatPrefs.hardwareEnterSends(
        keyboardSends: true,
        platform: TargetPlatform.android,
      ),
      isFalse,
    );
    expect(
      ChatPrefs.imeSends(
        keyboardSends: true,
        platform: TargetPlatform.android,
      ),
      isTrue,
    );
  });

  test('turning Enter off leaves a new line on both', () {
    expect(
      ChatPrefs.hardwareEnterSends(
        keyboardSends: false,
        platform: TargetPlatform.windows,
      ),
      isFalse,
    );
    expect(
      ChatPrefs.imeSends(
        keyboardSends: false,
        platform: TargetPlatform.android,
      ),
      isFalse,
    );
  });
}
