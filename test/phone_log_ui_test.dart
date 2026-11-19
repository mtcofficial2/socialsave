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
}
