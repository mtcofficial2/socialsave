import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_admin_screen.dart';
import 'package:social_save/features/chat/chat_api.dart';

void main() {
  final now = DateTime.now();
  const adaId = '0123456789abcdef0123456789abcdef';
  const benId = 'fedcba9876543210fedcba9876543210';
  final snapshot = ChatAdminSnapshot(
    storage: 's3',
    people: [
      ChatDirectoryEntry(
        username: 'ada',
        phone: '+256 700 000 111',
        email: 'ada@example.com',
        created: now.subtract(const Duration(days: 3)),
        lastSeen: now,
        hasPassword: true,
        hasRecovery: true,
      ),
      ChatDirectoryEntry(
        username: 'ben',
        phone: '256700000111',
        email: '',
        created: now.subtract(const Duration(days: 9)),
        hasPassword: false,
        sessions: const [
          ChatAdminSession(id: 'abc12345abcd', name: 'Ben pc', platform: 'windows'),
        ],
      ),
    ],
    devices: [
      ChatDeviceEntry(
        id: adaId,
        platform: 'android',
        version: '1.0.103',
        username: 'ada',
        name: 'Ada phone',
        signedIn: true,
        first: now.subtract(const Duration(days: 3)),
        seen: now,
        downloads: 1,
        lastDownload: now,
      ),
      ChatDeviceEntry(
        id: benId,
        platform: 'windows',
        version: '1.0.102',
        username: 'ben',
        name: 'Ben pc',
        first: now.subtract(const Duration(days: 40)),
        seen: now.subtract(const Duration(days: 10)),
      ),
    ],
    groups: [
      ChatAdminGroup(
        id: 'g-family',
        name: 'Family',
        owner: 'ada',
        members: 3,
        created: now.subtract(const Duration(days: 2)),
      ),
    ],
    reports: [
      ChatAdminReport(
        id: 'rp1',
        from: 'cam',
        target: 'ada',
        reason: 'spam',
        at: now.subtract(const Duration(hours: 2)),
      ),
    ],
  );

  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
      MethodCall call,
    ) async {
      return null;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
    await tester.pumpWidget(MaterialApp(home: ChatAdminScreen(preview: snapshot)));
    await tester.pumpAndSettle();
  }

  testWidgets('filters, details, and storage explain on a phone', (tester) async {
    await pump(tester, const Size(400, 1800));

    expect(find.textContaining('1 device opened'), findsOneWidget);
    expect(find.text('Saved online'), findsOneWidget);

    await tester.tap(find.text('Saved online'));
    await tester.pumpAndSettle();
    expect(find.textContaining('A restart keeps this list.'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('1.0.102 1'));
    await tester.pumpAndSettle();
    expect(find.text('1 of 2'), findsOneWidget);
    expect(find.text('Ben pc'), findsOneWidget);
    expect(find.text('Ada phone'), findsNothing);

    await tester.tap(find.byTooltip('Copy device id'));
    await tester.pumpAndSettle();
    expect(find.text('Copied device id'), findsOneWidget);

    await tester.tap(find.text('Ben pc'));
    await tester.pumpAndSettle();
    expect(find.text(benId), findsOneWidget);
    expect(find.textContaining('Last signed in as @ben'), findsWidgets);
    expect(find.text('No saves yet'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Monitor'), findsOneWidget);

    await tester.tap(find.text('People 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No password 1'));
    await tester.pumpAndSettle();
    expect(find.text('@ben'), findsOneWidget);
    expect(find.text('@ada'), findsNothing);
    expect(find.textContaining('Same phone as @ada'), findsOneWidget);

    await tester.tap(find.text('@ben'));
    await tester.pumpAndSettle();
    expect(find.text('No recovery code'), findsWidgets);
    expect(find.text('Sign out everywhere'), findsOneWidget);
    await tester.tap(find.text('Disable'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Their chats stay.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'family');
    await tester.pumpAndSettle();
    expect(find.text('1 match'), findsOneWidget);
    expect(find.text('Family'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'spam');
    await tester.pumpAndSettle();
    await tester.tap(find.text('@cam reported @ada'));
    await tester.pumpAndSettle();
    expect(
      find.text('Open chat starts your conversation with them.'),
      findsOneWidget,
    );
    expect(find.text('Open @ada'), findsOneWidget);
  });

  testWidgets('a wide window keeps the list beside the detail', (tester) async {
    await pump(tester, const Size(1200, 1400));

    await tester.tap(find.text('Ada phone'));
    await tester.pumpAndSettle();
    expect(find.text(adaId), findsOneWidget);
    expect(find.text('Ben pc'), findsOneWidget);
    expect(find.text('View @ada'), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
  });
}