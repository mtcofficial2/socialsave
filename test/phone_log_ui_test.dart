import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/library/phone_log_ui.dart';
import 'package:social_save/features/library/usb_link.dart';

void main() {
  test('a notification keeps its title and words', () {
    final entry = presentPhoneLog(const PhoneLogLine(
      at: '2026-11-19T00:25:00Z',
      text: 'YouTube: New from MKBHD. The phone is here.',
      kind: 'notification',
      title: 'YouTube',
      detail: 'New from MKBHD\nThe phone is here',
    ));
    expect(entry.kind, 'notification');
    expect(entry.title, 'YouTube');
    expect(entry.detail, 'New from MKBHD\nThe phone is here');
  });

  test('an older notification line still names the app', () {
    final entry = presentPhoneLog(const PhoneLogLine(
      at: '2026-11-19T00:25:00Z',
      text: 'A notification arrived from MyVJ.',
    ));
    expect(entry.kind, 'notification');
    expect(entry.title, 'MyVJ');
    expect(entry.detail, 'App name only');
  });

  test('an app session splits the name and the time', () {
    final entry = presentPhoneLog(const PhoneLogLine(
      at: '2026-11-19T00:30:00Z',
      text: 'Used YouTube for 12 minutes.',
    ));
    expect(entry.kind, 'used');
    expect(entry.title, 'YouTube');
    expect(entry.detail, 'Used for 12 minutes');
  });

  test('a hidden password stays in the passwords section', () {
    final entry = presentPhoneLog(const PhoneLogLine(
      at: '2026-11-19T00:25:00Z',
      text: 'Hidden. This notification looks like a password or a code.',
      kind: 'secret',
      title: 'Gmail',
      detail: 'Hidden. This notification looks like a password or a code.',
    ));
    expect(entry.kind, 'secret');
    expect(entry.title, 'Gmail');
    expect(entry.detail, 'Hidden until the owner allows passwords and codes.');
    expect(phoneLogBucket(entry), 'secrets');
    expect(phoneLogVisible(entry, section: 'secrets', app: '', query: 'gmail'), isTrue);
    expect(phoneLogVisible(entry, section: 'notifications', app: '', query: ''), isFalse);
  });

  test('an allowed password keeps the words and can be found', () {
    final entry = presentPhoneLog(const PhoneLogLine(
      at: '2026-11-19T00:25:00Z',
      text: 'Gmail: Your password is 1234.',
      kind: 'secret',
      title: 'Gmail',
      detail: 'Your password is 1234',
    ));
    final used = presentPhoneLog(const PhoneLogLine(
      at: '2026-11-19T00:30:00Z',
      text: 'Used YouTube for 12 minutes.',
    ));
    expect(entry.detail, 'Your password is 1234');
    expect(phoneLogVisible(entry, section: 'secrets', app: 'Gmail', query: '1234'), isTrue);
    expect(phoneLogVisible(used, section: 'apps', app: 'YouTube', query: '12'), isTrue);
    expect(phoneLogVisible(used, section: 'apps', app: 'YouTube', query: 'gmail'), isFalse);
    expect(phoneLogApps([entry, used]), ['Gmail', 'YouTube']);
  });
}
