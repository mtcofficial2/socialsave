import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/features/chat/chat_link_rules.dart';

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
    expect(chatTick(mine: true, id: -2, peerDelivered: 0, peerRead: 0, status: 'sending'), 'sending');
    expect(chatTick(mine: true, id: -2, peerDelivered: 9, peerRead: 9, status: 'failed'), 'failed');
    expect(chatTick(mine: false, id: -2, peerDelivered: 0, peerRead: 0, status: 'failed'), '');
  });

  test('preview and avatar stay stable', () {
    expect(chatPreview('hello', 'ada', 'ada'), 'You: hello');
    expect(chatPreview('hello', 'ben', 'ada'), 'hello');
    expect(chatPreview('', 'ben', 'ada'), 'No messages yet');
    expect(chatInitial('@ada'), 'A');
    expect(chatAvatarColor('ada'), chatAvatarColor('ada'));
    expect(chatAvatarColor('ada'), isNot(chatAvatarColor('ben_1')));
  });

  test('presence and voice clocks', () {
    expect(chatPresenceLabel(null, true, now, '6:41 PM'), '');
    expect(chatPresenceLabel(now, true, now, '6:05 PM'), 'online');
    expect(
      chatPresenceLabel(DateTime(2026, 10, 31, 18, 1), false, now, '6:01 PM'),
      'last seen today at 6:01 PM',
    );
    expect(
      chatPresenceLabel(DateTime(2026, 10, 30, 22), false, now, '10:00 PM'),
      'last seen yesterday',
    );
    expect(
      chatPresenceLabel(DateTime(2026, 10, 2, 8), false, now, '8:00 AM'),
      'last seen 2 Oct',
    );
    expect(chatClock(0), '0:00');
    expect(chatClock(61000), '1:01');
  });

  test('quotes, alerts, and public links', () {
    expect(chatQuoteLabel('hello', voice: true, photo: false), 'Voice message');
    expect(chatQuoteLabel('Photo', voice: false, photo: true), 'Photo');
    expect(chatQuoteLabel('look here', voice: false, photo: true), 'look here');
    expect(chatQuoteLabel('a' * 90, voice: false, photo: false), 'a' * 80);
    expect(chatAlertBody('Voice message'), 'Voice message');
    expect(chatAlertBody('Photo'), 'Photo');
    expect(chatAlertBody('  hello  '), 'hello');
    expect(chatAlertBody(''), 'New message');
    expect(chatLinkAllowed(Uri.parse('https://example.com/watch')), isTrue);
    expect(chatLinkAllowed(Uri.parse('http://example.com/watch')), isFalse);
    expect(chatLinkAllowed(Uri.parse('https://127.0.0.1/secret')), isFalse);
    expect(chatLinkAllowed(Uri.parse('https://10.0.0.4/secret')), isFalse);
    expect(chatLinkAllowed(Uri.parse('https://192.168.1.2/secret')), isFalse);
    expect(chatLinkAllowed(Uri.parse('https://localhost/secret')), isFalse);
  });
}
