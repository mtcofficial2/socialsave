import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_format.dart';

void main() {
  final now = DateTime(2026, 10, 31, 18, 5);

  test('day labels and list stamps', () {
    expect(chatDayLabel(DateTime(2026, 10, 31, 9), now), 'Today');
    expect(chatListStamp(DateTime(2026, 10, 31, 9), now, '9:00 AM'), '9:00 AM');
    expect(chatDayLabel(DateTime(2026, 10, 30, 22), now), 'Yesterday');
    expect(chatListStamp(DateTime(2026, 10, 30, 22), now, '10:00 PM'), 'Yesterday');
    expect(chatDayLabel(DateTime(2026, 10, 2, 8), now), '2 Oct 2026');
    expect(chatListStamp(DateTime(2026, 10, 2, 8), now, '8:00 AM'), '2 Oct');
  });

  test('unread ignores your own last message', () {
    expect(
      chatThreadUnread(lastFrom: 'ben', lastId: 4, me: 'ada', seenId: 2),
      isTrue,
    );
    expect(
      chatThreadUnread(lastFrom: 'ada', lastId: 4, me: 'ada', seenId: 2),
      isFalse,
    );
    expect(
      chatThreadUnread(lastFrom: 'ben', lastId: 4, me: 'ada', seenId: 4),
      isFalse,
    );
    expect(
      chatThreadUnread(lastFrom: '', lastId: 0, me: 'ada', seenId: 0),
      isFalse,
    );
  });

  test('ticks move from sent to read', () {
    expect(chatTick(mine: false, id: 3, peerDelivered: 9, peerRead: 9), '');
    expect(chatTick(mine: true, id: 3, peerDelivered: 0, peerRead: 0), 'sent');
    expect(chatTick(mine: true, id: 3, peerDelivered: 3, peerRead: 0), 'delivered');
    expect(chatTick(mine: true, id: 3, peerDelivered: 3, peerRead: 3), 'read');
    expect(chatTick(mine: true, id: 4, peerDelivered: 3, peerRead: 3, status: 'sent'), 'sent');
  });

  test('preview and avatar stay stable', () {
    expect(chatPreview('hello', 'ada', 'ada'), 'You: hello');
    expect(chatPreview('hello', 'ben', 'ada'), 'hello');
    expect(chatPreview('', 'ben', 'ada'), 'No messages yet');
    expect(chatInitial('@ada'), 'A');
    expect(chatAvatarColor('ada'), chatAvatarColor('ada'));
    expect(chatAvatarColor('ada'), isNot(chatAvatarColor('ben_1')));
  });
}
