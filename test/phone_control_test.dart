import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/library/phone_control.dart';
import 'package:social_save/features/library/phone_control_ui.dart';

void main() {
  test('only a normal package name can be opened', () {
    expect(phoneControlPackage('com.android.chrome'), isTrue);
    expect(phoneControlPackage('com.socialsave.social_save'), isTrue);
    expect(phoneControlPackage('a.b'), isTrue);
    expect(phoneControlPackage('Settings'), isFalse);
    expect(phoneControlPackage('com.foo;id'), isFalse);
    expect(phoneControlPackage('com.foo bar'), isFalse);
    expect(phoneControlPackage('.a.b'), isFalse);
    expect(phoneControlPackage(''), isFalse);
  });

  test('the cable list drops paths and unsafe packages', () {
    final wire = phoneControlWireApps([
      {
        'name': 'Chrome',
        'package': 'com.android.chrome',
        'system': false,
        'apks': ['/data/app/chrome.apk'],
        'icon': '/cache/chrome.png',
      },
      {'name': 'Bad', 'package': 'com.foo;rm', 'system': false},
      {'name': '', 'package': 'com.example.app', 'system': false},
    ]);
    expect(wire, hasLength(1));
    expect(wire.single.keys, ['name', 'package', 'system']);
    expect(wire.single['package'], 'com.android.chrome');

    final apps = phoneControlApps({
      'apps': [
        {'name': 'Zed', 'package': 'com.zed.app', 'system': false},
        {'name': 'Settings', 'package': 'com.android.settings', 'system': true},
        {'name': 'Nope', 'package': 'not a package'},
      ],
    });
    expect(apps.map((app) => app.name).toList(), ['Zed', 'Settings']);
    expect(apps.last.system, isTrue);
  });

  test('a screen shot reports its size and a tap lands on the picture', () {
    final bytes = List<int>.filled(24, 0);
    bytes[0] = 0x89;
    bytes[1] = 0x50;
    bytes[2] = 0x4e;
    bytes[3] = 0x47;
    bytes[16] = 0;
    bytes[17] = 0;
    bytes[18] = 0;
    bytes[19] = 100;
    bytes[20] = 0;
    bytes[21] = 0;
    bytes[22] = 1;
    bytes[23] = 144;
    expect(pngSize(bytes), (100, 400));
    expect(pngSize([1, 2, 3]), isNull);

    final hit = phoneControlTap(localX: 100, localY: 200, boxW: 200, boxH: 400, imageW: 100, imageH: 400);
    expect(hit, (x: 50, y: 200));
    final miss = phoneControlTap(localX: 10, localY: 200, boxW: 200, boxH: 400, imageW: 100, imageH: 400);
    expect(miss, isNull);
  });

  test('typed words are cleaned and quoted as one shell word', () {
    expect(phoneControlType('  hello   there  '), 'hello there');
    expect(phoneControlType('a\nb'), 'a b');
    expect(phoneControlType('   '), '');
    expect(phoneControlType('x' * 250).length, 200);
    expect(phoneControlShellQuote("it's; rm -rf"), r"'it'\''s; rm -rf'");
    expect(phoneControlMatches(const PhoneControlApp(name: 'Camera', packageName: 'com.android.camera', system: true), 'cam'), isTrue);
    expect(phoneControlMatches(const PhoneControlApp(name: 'Camera', packageName: 'com.android.camera', system: true), 'chrome'), isFalse);
  });

  testWidgets('the control sheet opens an app and does not keep typed words', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: PhoneControlSheet(
          previewPhones: [(serial: 'phone', name: 'AQUOS')],
          previewApps: [
            PhoneControlApp(name: 'Chrome', packageName: 'com.android.chrome', system: false),
            PhoneControlApp(name: 'Camera', packageName: 'com.android.camera', system: true),
          ],
        ),
      ),
    );
    expect(find.text('Chrome'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('phone-control-search')), 'cam');
    await tester.pump();
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Chrome'), findsNothing);

    await tester.enterText(find.byKey(const ValueKey('phone-control-search')), '');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('phone-control-app-com.android.chrome')));
    await tester.pump();
    expect(find.text('Opened Chrome.'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('phone-control-type')), 'secret-code-9421');
    await tester.tap(find.byKey(const ValueKey('phone-control-type-send')));
    await tester.pump();
    expect(find.text('Typed into the open field.'), findsOneWidget);
    expect(find.textContaining('secret-code-9421'), findsNothing);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('phone-control-type'))).controller!.text, isEmpty);

    await tester.tap(find.byKey(const ValueKey('phone-control-screen')));
    await tester.pump();
    expect(find.text('Tapped the phone screen.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('phone-control-back')));
    await tester.pump();
    expect(find.text('Pressed Back.'), findsOneWidget);
  });

  testWidgets('an older phone still shows the screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: PhoneControlSheet(
          previewPhones: [(serial: 'phone', name: 'AQUOS')],
          previewNamed: false,
        ),
      ),
    );
    expect(find.textContaining('Update Social Save on the phone'), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-control-screen')), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-control-home')), findsOneWidget);
  });
}
