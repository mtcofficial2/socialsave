import 'package:flutter/material.dart';
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

  test('an app opens onto its password rows, and Google groups Gmail and Chrome', () {
    final gmail = presentPhoneLog(const PhoneLogLine(
      at: '2026-11-19T00:25:00Z',
      text: 'Gmail: Your password is 1234.',
      kind: 'secret',
      title: 'Gmail',
      detail: 'Your password is 1234',
    ));
    final chrome = presentPhoneLog(const PhoneLogLine(
      at: '2026-11-19T00:26:00Z',
      text: 'Chrome: Your code is 999000.',
      kind: 'secret',
      title: 'Chrome',
      detail: 'Your code is 999000',
    ));
    final hidden = presentPhoneLog(const PhoneLogLine(
      at: '2026-11-19T00:27:00Z',
      text: 'Hidden. This notification looks like a password or a code.',
      kind: 'secret',
      title: 'Gmail',
      detail: 'Hidden. This notification looks like a password or a code.',
    ));
    final youtube = presentPhoneLog(const PhoneLogLine(
      at: '2026-11-19T00:30:00Z',
      text: 'Used YouTube for 12 minutes.',
    ));
    final rows = phoneLogAppRows([gmail, chrome, hidden, youtube]);
    expect(rows.first.keyName, phoneLogGoogleKey);
    expect(rows.first.passwords, 3);
    expect(rows.first.events, 0);
    expect(rows.map((row) => row.keyName), [phoneLogGoogleKey, 'Gmail', 'Chrome', 'YouTube']);
    expect(rows[1].passwords, 2);
    expect(rows[3].events, 1);
    final googlePasswords = [
      for (final entry in [gmail, chrome, hidden, youtube])
        if (entry.kind == 'secret' && phoneLogInApp(entry, phoneLogGoogleKey)) entry,
    ];
    expect(googlePasswords.map((entry) => entry.title), ['Gmail', 'Chrome', 'Gmail']);
    expect(phoneLogInApp(youtube, 'YouTube'), isTrue);
    expect(phoneLogInApp(gmail, 'YouTube'), isFalse);
    expect(phoneLogPasswordEmpty(phoneLogGoogleKey), contains('Google Password Manager'));
    expect(phoneLogPasswordEmpty('YouTube'), contains('showed it on a notification'));
    expect(phoneLogAppMatches(rows.first, [gmail, chrome, hidden, youtube], '1234'), isTrue);
    expect(phoneLogAppMatches(rows.first, [gmail, chrome, hidden, youtube], 'youtube'), isFalse);
    expect(phoneLogAppMatches(rows[3], [gmail, chrome, hidden, youtube], '12'), isTrue);
    expect(phoneLogSecretLabel(gmail), 'Your password is 1234');
    expect(phoneLogSecretLabel(hidden), 'Hidden');
    expect(phoneLogAppCount(rows.first), '3 passwords · 0 events');
    expect(phoneLogAppCount(const PhoneLogAppRow(keyName: phoneLogGoogleKey, label: 'Google', passwords: 0, events: 0, google: true)), 'Nothing from a Google notification yet');
  });

  testWidgets('tapping an app shows its password rows, and Google groups those notifications', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PhoneLogSheet(preview: [
          PluggedPhoneLog(
            serial: 'test',
            name: 'Sharp',
            lines: const [
              PhoneLogLine(
                at: '2026-11-19T00:25:00Z',
                text: 'Gmail: Your password is 1234.',
                kind: 'secret',
                title: 'Gmail',
                detail: 'Your password is 1234',
              ),
              PhoneLogLine(
                at: '2026-11-19T00:26:00Z',
                text: 'Chrome: Your code is 999000.',
                kind: 'secret',
                title: 'Chrome',
                detail: 'Your code is 999000',
              ),
              PhoneLogLine(
                at: '2026-11-19T00:30:00Z',
                text: 'Used YouTube for 12 minutes.',
              ),
            ],
          ),
        ]),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Google'), findsOneWidget);
    expect(find.text('Gmail'), findsOneWidget);
    expect(find.text('Your password is 1234'), findsNothing);

    await tester.tap(find.text('Gmail'));
    await tester.pumpAndSettle();
    expect(find.text('Your password is 1234'), findsOneWidget);
    expect(find.text('Your code is 999000'), findsNothing);

    await tester.tap(find.byTooltip('All apps'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Google'));
    await tester.pumpAndSettle();
    expect(find.text('Your password is 1234'), findsOneWidget);
    expect(find.text('Your code is 999000'), findsOneWidget);
    expect(find.text('Google Password Manager'), findsNothing);

    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expect(find.text('This app has no other activity in the log.'), findsOneWidget);
  });
}
