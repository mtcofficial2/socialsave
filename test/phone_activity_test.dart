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
