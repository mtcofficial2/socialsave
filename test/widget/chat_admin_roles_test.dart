import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_admin_screen.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_monitor.dart';

void main() {
  group('role and permission model', () {
    test('an older server reply means the owner with every permission', () {
      final access = chatAdminAccess(<String, dynamic>{'users': <Object>[]});
      expect(access.role, 'owner');
      expect(access.permissions, chatAllPermissions);
    });

    test('unknown permissions from the server are dropped', () {
      final access = chatAdminAccess(<String, dynamic>{
        'role': 'support',
        'permissions': ['users.view', 'root.everything', 'sessions.end'],
      });
      expect(access.role, 'support');
      expect(access.permissions, ['users.view', 'sessions.end']);
    });

    test('a staff role opens Monitor, a normal account does not', () {
      const plain = ChatUser(id: 'u1', username: 'ada', phone: '', email: '');
      expect(plain.isAdmin, isFalse);
      final mod = ChatUser.fromJson({'id': 'u2', 'username': 'mo', 'role': 'moderator'});
      expect(mod.role, 'moderator');
      expect(mod.isAdmin, isTrue);
      expect(mod.copyWith(photoRev: 2).role, 'moderator');
      final bogus = ChatUser.fromJson({'id': 'u3', 'username': 'x', 'role': 'root'});
      expect(bogus.isAdmin, isFalse);
    });

    test('tabs follow permissions and ranks only go down', () {
      expect(monitorTabsFor(chatAllPermissions), MonitorTab.values);
      expect(
        monitorTabsFor(['users.view', 'groups.view', 'reports.view']),
        [MonitorTab.people, MonitorTab.groups, MonitorTab.reports],
      );
      expect(monitorOutranks('owner', 'admin'), isTrue);
      expect(monitorOutranks('admin', 'admin'), isFalse);
      expect(monitorOutranks('moderator', 'admin'), isFalse);
      expect(monitorOutranks('support', ''), isTrue);
    });

    test('audit filters by action and search', () {
      final now = DateTime.now();
      final audit = [
        ChatAdminAudit(actor: 'mo', action: 'account.disable', target: 'ada', at: now),
        ChatAdminAudit(
          actor: 'daniel256',
          action: 'role',
          target: 'mo',
          detail: 'moderator',
          at: now.subtract(const Duration(minutes: 1)),
        ),
      ];
      expect(monitorFilterAudit(audit, '', 'role').single.target, 'mo');
      expect(monitorFilterAudit(audit, '@ada', '').single.action, 'account.disable');
      expect(monitorSortAudit(audit, MonitorAuditSort.oldest).first.action, 'role');
    });
  });

  Future<void> pump(WidgetTester tester, ChatAdminSnapshot snapshot) async {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async => null,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await tester.pumpWidget(MaterialApp(home: ChatAdminScreen(preview: snapshot)));
    await tester.pumpAndSettle();
  }

  final now = DateTime.now();
  final people = [
    ChatDirectoryEntry(
      username: 'ada',
      phone: '',
      email: '',
      created: now,
      sessions: const [ChatAdminSession(id: 'abc12345abcd', name: 'Ada pc', platform: 'windows')],
    ),
    ChatDirectoryEntry(username: 'boss', phone: '', email: '', created: now, role: 'admin'),
  ];

  testWidgets('a moderator sees only its tabs and actions', (tester) async {
    await pump(
      tester,
      ChatAdminSnapshot(
        role: 'moderator',
        permissions: const ['users.view', 'users.disable', 'groups.view', 'reports.view', 'reports.dismiss', 'messages.remove'],
        storage: 's3',
        people: people,
        devices: const [],
        reports: [ChatAdminReport(id: 'r1', from: 'boss', target: 'ada', reason: 'spam', at: now)],
      ),
    );
    expect(find.text('Moderator'), findsOneWidget);
    expect(find.textContaining('Devices'), findsNothing);
    expect(find.text('Audit 0'), findsNothing);
    expect(find.text('People 2'), findsOneWidget);
    expect(find.text('Open reports'), findsOneWidget);

    await tester.tap(find.text('@ada'));
    await tester.pumpAndSettle();
    expect(find.text('Disable'), findsOneWidget);
    expect(find.text('Review messages'), findsOneWidget);
    expect(find.text('Change role'), findsNothing);
    expect(find.text('Sign out'), findsNothing);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    // An admin outranks a moderator, so there is nothing to press.
    await tester.tap(find.text('@boss'));
    await tester.pumpAndSettle();
    expect(find.text('Role: Admin'), findsOneWidget);
    expect(find.text('Disable'), findsNothing);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reports 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('@boss reported @ada'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dismiss report'));
    await tester.pumpAndSettle();
    expect(find.text('Dismiss this report?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('the owner gets roles, audit, and paged lists', (tester) async {
    await pump(
      tester,
      ChatAdminSnapshot(
        storage: 's3',
        people: [
          for (var i = 0; i < 60; i++)
            ChatDirectoryEntry(
              username: 'user$i',
              phone: '',
              email: '',
              created: now.subtract(Duration(minutes: i)),
            ),
        ],
        devices: const [],
        audit: [ChatAdminAudit(actor: 'mo', action: 'account.disable', target: 'user1', at: now)],
      ),
    );
    expect(find.text('Owner'), findsOneWidget);
    await tester.tap(find.text('People 60'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('@user0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change role'));
    await tester.pumpAndSettle();
    expect(find.text('Role for @user0'), findsOneWidget);
    expect(find.text('Moderator'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    final list = find.descendant(
      of: find.byKey(const Key('monitor-list')),
      matching: find.byType(Scrollable),
    ).first;
    await tester.scrollUntilVisible(find.byKey(const Key('monitor-more')), 600, scrollable: list);
    expect(find.text('Show more (10 left)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('monitor-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('monitor-more')), findsNothing);
    await tester.scrollUntilVisible(find.text('@user59'), 600, scrollable: list);
    expect(find.text('@user59'), findsOneWidget);


    await tester.drag(find.byKey(const Key('monitor-list')), const Offset(0, 20000));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Audit 1'));
    await tester.pumpAndSettle();
    expect(find.text('Turned off'), findsWidgets);
    expect(find.text('@mo → @user1'), findsOneWidget);
  });
}
