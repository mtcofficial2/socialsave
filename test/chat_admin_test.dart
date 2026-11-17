import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_monitor.dart';

void main() {
  test('only the admin phone and username can open the people list', () {
    const admin = ChatUser(
      id: '1',
      username: 'daniel256',
      phone: '256703487378',
      email: '',
    );
    const spaced = ChatUser(
      id: '1',
      username: '@daniel256',
      phone: '+256 703 487 378',
      email: '',
    );
    const otherPhone = ChatUser(
      id: '1',
      username: 'daniel256',
      phone: '256700000111',
      email: '',
    );
    const otherName = ChatUser(
      id: '1',
      username: 'ada',
      phone: '256703487378',
      email: '',
    );

    expect(chatUserIsAdmin(admin), isTrue);
    expect(admin.isAdmin, isTrue);
    expect(chatUserIsAdmin(spaced), isTrue);
    expect(chatUserIsAdmin(otherPhone), isFalse);
    expect(chatUserIsAdmin(otherName), isFalse);
    expect(chatUserIsAdmin(null), isFalse);
  });

  test('a private name replaces the username only on this account', () {
    const named = ChatThreadSummary(id: 't1', username: 'ben7', name: 'Benny');
    const plain = ChatThreadSummary(id: 't1', username: 'ben7');
    expect(named.label, 'Benny');
    expect(plain.label, 'ben7');
    expect(named.copyWith(name: '').label, 'ben7');
  });

  test('the people list reads last seen and whether a password is set', () {
    final row = ChatDirectoryEntry.fromJson({
      'username': 'ada',
      'phone': '256700000111',
      'email': '',
      'created': 1700000000000,
      'lastSeen': 1700000001000,
      'hasPassword': true,
    });
    expect(row.username, 'ada');
    expect(row.hasPassword, isTrue);
    expect(row.lastSeen, DateTime.fromMillisecondsSinceEpoch(1700000001000));
    final open = ChatDirectoryEntry.fromJson({
      'username': 'ben',
      'created': 1,
    });
    expect(open.hasPassword, isFalse);
    expect(open.lastSeen, isNull);
  });

  test('a device row reads the platform, version, and last open', () {
    final row = ChatDeviceEntry.fromJson({
      'id': '0123456789abcdef0123456789abcdef',
      'platform': 'android',
      'version': '1.0.83',
      'username': 'ada',
      'name': 'AQUOS R7',
      'model': 'SHARP A202SH',
      'downloads': 2,
      'first': 1700000000000,
      'seen': 1700000001000,
    });
    expect(row.platform, 'android');
    expect(row.version, '1.0.83');
    expect(row.username, 'ada');
    expect(row.name, 'AQUOS R7');
    expect(row.model, 'SHARP A202SH');
    expect(row.downloads, 2);
    expect(row.seen, DateTime.fromMillisecondsSinceEpoch(1700000001000));
    expect(row.signedIn, isFalse);
    expect(chatDevicePlatform(), isNotNull);
    final signed = ChatDeviceEntry.fromJson({
      'id': '0123456789abcdef0123456789abcdef',
      'platform': 'android',
      'version': '1.0.103',
      'username': 'ada',
      'signedIn': true,
      'first': 1,
      'seen': 1,
    });
    expect(signed.signedIn, isTrue);
    expect(monitorAccountLine(signed), '@ada');
    expect(monitorAccountLine(row), 'Last signed in as @ada');
  });

  test('monitor filters versions, quiet devices, and shared phones', () {
    final now = DateTime(2026, 11, 17, 12);
    final ada = ChatDeviceEntry(
      id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      platform: 'android',
      version: '1.0.103',
      username: 'ada',
      name: 'Ada phone',
      signedIn: true,
      first: now,
      seen: now,
      downloads: 2,
      lastDownload: now,
    );
    final ben = ChatDeviceEntry(
      id: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      platform: 'windows',
      version: '1.0.90',
      username: 'ben',
      name: 'Ben pc',
      first: now.subtract(const Duration(days: 40)),
      seen: now.subtract(const Duration(days: 10)),
    );
    final versions = monitorVersions([ada, ben]);
    expect(versions.chips.map((chip) => chip.label), ['1.0.103', '1.0.90']);
    final old = monitorFilterDevices(
      devices: [ada, ben],
      query: '',
      platform: '',
      versionKey: '1.0.90',
      versions: versions,
      freshness: MonitorFreshness.any,
      signedInOnly: false,
      now: now,
    );
    expect(old.map((device) => device.name), ['Ben pc']);
    final quiet = monitorFilterDevices(
      devices: [ada, ben],
      query: '',
      platform: '',
      versionKey: '',
      versions: versions,
      freshness: MonitorFreshness.quiet7,
      signedInOnly: false,
      now: now,
    );
    expect(quiet.map((device) => device.name), ['Ben pc']);
    expect(monitorCapNote(2000, 2000), 'Showing the 2,000 most recently opened.');
    expect(monitorCapNote(3, 2000), isEmpty);
    final people = [
      const ChatDirectoryEntry(
        username: 'ada',
        phone: '+256 700 000 111',
        email: '',
        created: null,
        hasPassword: true,
        hasRecovery: true,
      ),
      const ChatDirectoryEntry(
        username: 'ben',
        phone: '256700000111',
        email: '',
        created: null,
      ),
    ];
    expect(monitorShares(people)['ben']?.line, 'Same phone as @ada');
    final missing = monitorFilterPeople(
      people: people,
      query: '',
      password: MonitorPassword.missing,
      noContact: false,
      noRecovery: false,
    );
    expect(missing.single.username, 'ben');
    final today = monitorToday(
      people: people,
      devices: [ada, ben],
      reports: const [],
      now: now,
    );
    expect(today.opened, 1);
    expect(today.saves, 1);
    expect(today.line, contains('1 device opened'));
  });
}
