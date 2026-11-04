import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/library/app_share.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ss-apps');
    InstalledApps.debugLoader = null;
    InstalledApps.cached = null;
    InstalledApps.results.value = null;
    InstalledApps.scanning.value = false;
  });

  tearDown(() {
    InstalledApps.debugLoader = null;
    InstalledApps.cached = null;
    InstalledApps.results.value = null;
    InstalledApps.scanning.value = false;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  PhoneApp app({
    required String name,
    required String packageName,
    required List<String> apks,
    bool system = false,
    String version = '1.0',
  }) {
    return PhoneApp(
      name: name,
      packageName: packageName,
      version: version,
      size: 10,
      system: system,
      iconPath: '',
      apkPaths: apks,
    );
  }

  test('one app is sent as a single named apk', () async {
    final file = File('${dir.path}${Platform.pathSeparator}base.apk')..writeAsStringSync('apk');
    final bundle = bundleForApps([
      app(name: 'Maps', packageName: 'com.maps', apks: [file.path]),
    ]);
    expect(bundle, isNotNull);
    expect(bundle!.isFolder, isFalse);
    expect(bundle.label, 'Maps');
    expect(bundle.items.single.rel, 'Maps.apk');
    expect(bundle.items.single.size, file.lengthSync());
  });

  test('several apps keep each apk in its own folder', () async {
    final maps = File('${dir.path}${Platform.pathSeparator}maps.apk')..writeAsStringSync('a');
    final split = File('${dir.path}${Platform.pathSeparator}split.apk')..writeAsStringSync('bb');
    final bundle = bundleForApps([
      app(name: 'Maps', packageName: 'com.maps', apks: [maps.path, split.path]),
      app(name: 'Notes: today', packageName: 'com.notes', apks: [maps.path]),
    ]);
    expect(bundle!.isFolder, isTrue);
    expect(bundle.label, '2 apps');
    expect(bundle.items.map((item) => item.rel).toList(), [
      'Maps/maps.apk',
      'Maps/split.apk',
      'Notes today/maps.apk',
    ]);
  });

  test('parse drops a row with no apk', () {
    expect(PhoneApp.parse({'name': 'Maps', 'package': 'com.maps', 'apks': const []}), isNull);
    final parsed = PhoneApp.parse({
      'name': ' Maps ',
      'package': 'com.maps',
      'version': '2',
      'size': 12,
      'system': false,
      'icon': '',
      'apks': ['/data/app/base.apk'],
    });
    expect(parsed?.name, 'Maps');
    expect(parsed?.size, 12);
  });

  testWidgets('user apps are ready to send and system apps stay hidden', (tester) async {
    final file = File('${dir.path}${Platform.pathSeparator}base.apk')..writeAsStringSync('apk');
    InstalledApps.debugLoader = () async => [
      app(name: 'Maps', packageName: 'com.maps', apks: [file.path]),
      app(name: 'Settings', packageName: 'com.android.settings', apks: [file.path], system: true),
    ];
    await tester.pumpWidget(const MaterialApp(home: AppShareScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Maps'), findsOneWidget);
    expect(find.text('Settings'), findsNothing);
    expect(find.text('1 app ready to send'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('app-row-com.maps')));
    await tester.pump();
    expect(find.byKey(const ValueKey('app-send')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('app-system')));
    await tester.pump();
    expect(find.text('Settings'), findsOneWidget);
  });
}
