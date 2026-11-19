import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/core/diagnostics/phone_activity.dart';
import 'package:social_save/core/diagnostics/plain_log.dart';

void main() {
  setUp(() {
    PlainLog.debugReset();
    PhoneActivity.debugReset();
  });
  tearDown(() {
    PlainLog.debugReset();
    PhoneActivity.debugReset();
  });

  test('the fuller log waits until the owner answers', () async {
    PhoneActivity.debugConsent = () async => null;
    final lines = await PhoneActivity.forCable();
    expect(
      lines.map((line) => line['text']),
      contains('The owner of this phone has not allowed the fuller log yet.'),
    );
  });

  test('a local stamp and a UTC stamp are the same moment', () {
    final utc = DateTime.utc(2026, 11, 19, 1, 5, 6);
    final localStamp = utc.toLocal().toIso8601String();
    final utcStamp = utc.toIso8601String();
    expect(PhoneActivity.instant(localStamp), PhoneActivity.instant(utcStamp));
    final minuteLater = utc.toLocal().add(const Duration(minutes: 1)).toIso8601String();
    expect(PhoneActivity.instant(utcStamp).isBefore(PhoneActivity.instant(minuteLater)), isTrue);
  });

  test('no stays off and does not ask again', () async {
    PhoneActivity.debugConsent = () async => false;
    var asked = false;
    PhoneActivity.prompt = () async {
      asked = true;
      return true;
    };
    final lines = await PhoneActivity.forCable();
    expect(asked, isFalse);
    expect(
      lines.map((line) => line['text']),
      contains('The owner of this phone left the fuller log off. They can turn it on in Settings.'),
    );
  });
}
