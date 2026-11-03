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
}
