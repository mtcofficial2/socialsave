import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_api.dart';

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
      'first': 1700000000000,
      'seen': 1700000001000,
    });
    expect(row.platform, 'android');
    expect(row.version, '1.0.83');
    expect(row.username, 'ada');
    expect(row.seen, DateTime.fromMillisecondsSinceEpoch(1700000001000));
    expect(chatDevicePlatform(), isNotNull);
  });
}
