import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/core/diagnostics/plain_log.dart';

void main() {
  setUp(PlainLog.debugReset);
  tearDown(PlainLog.debugReset);

  test('known diagnostics become plain sentences', () {
    expect(
      PlainLog.plainEnglish('[session] connected Asha 192.168.1.8:47325 via usb'),
      'Connected to Asha over the USB cable.',
    );
    expect(
      PlainLog.plainEnglish('[session] ended: the other person left'),
      'The share ended. the other person left',
    );
    expect(
      PlainLog.plainEnglish('[session] download of clip.mp4 failed: the connection dropped'),
      'Could not receive clip.mp4. the connection dropped',
    );
    expect(
      PlainLog.plainEnglish('[session] cable open 127.0.0.1:1 via usb -> ok'),
      'The cable share opened.',
    );
    expect(
      PlainLog.plainEnglish('[session] no answer for 12s: reconnecting'),
      'No answer for 12 seconds. Trying again.',
    );
    expect(
      PlainLog.plainEnglish('[usb] quick action offered for Sharp'),
      'Offered to share files with Sharp.',
    );
    expect(
      PlainLog.plainEnglish('[hotspot] reopen failed: Wi-Fi is off'),
      'Could not turn the hotspot back on. Wi-Fi is off',
    );
    expect(PlainLog.plainEnglish('[tray] init failed: missing icon'), 'The tray icon did not start. missing icon');
  });

  test('secrets and unknown lines are dropped', () {
    expect(PlainLog.plainEnglish('[session] connected token abc via usb'), isNull);
    expect(PlainLog.plainEnglish('password=hunter2'), isNull);
    expect(PlainLog.plainEnglish('[player] codec failed'), isNull);
    expect(PlainLog.plainEnglish('just a note'), isNull);
  });

  test('the same sentence is kept once until it changes', () {
    PlainLog.note('Social Save opened.');
    PlainLog.note('Social Save opened.');
    PlainLog.note('Saved "Flower".');
    expect(PlainLog.lines.map((line) => line.text).toList(), [
      'Social Save opened.',
      'Saved "Flower".',
    ]);
  });
}
