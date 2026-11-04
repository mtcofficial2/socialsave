import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_api.dart';

void main() {
  test('a reaction, an edit, and a song stay on the message', () {
    final message = ChatMessage.fromJson({
      'id': 3,
      'from': 'a',
      'name': 'ada',
      'text': 'hello there',
      'at': 1700000000000,
      'editedAt': 1700000001000,
      'song': 's1',
      'songName': 'Hello',
      'songMs': 1000,
      'songType': 'wav',
      'reactions': [
        {'user': 'ben', 'emoji': '👍'},
      ],
    });
    expect(message.isSong, isTrue);
    expect(message.isEdited, isTrue);
    expect(message.reactions.single.emoji, '👍');
    final again = ChatMessage.fromJson(message.toJson());
    expect(again.songName, 'Hello');
    expect(again.text, 'hello there');
    expect(again.reactions.single.user, 'ben');

    final kept = message.withQuoteFrom(
      ChatMessage(
        id: 3,
        from: 'a',
        name: 'ada',
        text: 'hello',
        links: const [],
        at: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        replyText: 'quoted',
        replyName: 'ben',
        reply: 1,
      ),
    );
    expect(kept.text, 'hello there');
    expect(kept.replyText, 'quoted');
    expect(kept.isSong, isTrue);
  });

  test('a group and a block stay on the chat row', () {
    final row = ChatThreadSummary.fromJson({
      'id': 'gabc',
      'username': '',
      'name': 'Family',
      'group': true,
      'members': 2,
      'blocked': true,
    });
    expect(row.group, isTrue);
    expect(row.blocked, isTrue);
    expect(row.members, 2);
    expect(row.label, 'Family');
    final renamed = row.copyWith(name: 'Home');
    expect(renamed.group, isTrue);
    expect(renamed.blocked, isTrue);
    expect(renamed.label, 'Home');
  });

  test('message info reads the server times', () {
    final info = ChatMessageInfo.fromJson({
      'id': 1,
      'at': 1700000000000,
      'editedAt': 1700000001000,
      'deliveredAt': 1700000002000,
      'readAt': 1700000003000,
    });
    expect(info.id, 1);
    expect(info.editedAt, isNotNull);
    expect(info.readAt!.isAfter(info.deliveredAt!), isTrue);
  });
}
