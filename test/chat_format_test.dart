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

  test('written usernames split out of a message', () {
    final hello = chatTextPieces('hello @Ada');
    expect(hello.map((piece) => piece.text).toList(), ['hello ', '@Ada']);
    expect(hello[1].username, 'ada');
    expect(hello[1].link, isNull);

    final email = chatTextPieces('mail user@ada.com today');
    expect(email, hasLength(1));
    expect(email.single.username, isNull);
    expect(email.single.text, 'mail user@ada.com today');

    final linked = chatTextPieces(
      'go https://x.com/@ada now @ben',
      ['https://x.com/@ada'],
    );
    expect(linked.map((piece) => piece.text).toList(), [
      'go ',
      'https://x.com/@ada',
      ' now ',
      '@ben',
    ]);
    expect(linked[1].link, 'https://x.com/@ada');
    expect(linked[1].username, isNull);
    expect(linked[3].username, 'ben');

    final inside = chatTextPieces('see https://x.com/@ada please');
    expect(inside.where((piece) => piece.isUsername), isEmpty);

    expect(chatTextPieces('@ab').single.username, isNull);
    expect(chatTextPieces('@a_b').single.username, 'a_b');
    expect(chatTextPieces('(@zo_e)').map((piece) => piece.username).toList(), [
      null,
      'zo_e',
      null,
    ]);
    expect(chatTextPieces('@${'a' * 21}').single.username, isNull);
    expect(chatTextPieces('').single.text, '');
  });

  test('a status reply keeps the status line in the message', () {
    expect(statusReplySnippet('  hello  ', photo: false), 'hello');
    expect(statusReplySnippet('', photo: true), 'Photo');
    expect(statusReplySnippet('', photo: false), 'Update');
    expect(statusReplySnippet('a' * 90, photo: false), 'a' * 80);
    expect(statusReplyBody('Photo', 'on my way'), 'Status: Photo\non my way');
    expect(statusReplyBody('Photo', ''), 'Status: Photo');
    expect(statusReplyBody('', 'hi'), 'hi');
    expect(
      statusReplyBody('sunset', 'on my way', id: 'stabc', photo: true),
      'Status#stabc|photo: sunset\non my way',
    );
    final parts = parseStatusReply('Status: Photo\non my way');
    expect(parts?.snippet, 'Photo');
    expect(parts?.reply, 'on my way');
    expect(parts?.id, '');
    expect(parts?.photo, isFalse);
    final photo = parseStatusReply('Status#stabc|photo: sunset\non my way');
    expect(photo?.id, 'stabc');
    expect(photo?.photo, isTrue);
    expect(photo?.snippet, 'sunset');
    expect(photo?.reply, 'on my way');
    expect(parseStatusReply('Status: hello')?.reply, '');
    expect(parseStatusReply('hello'), isNull);
    expect(statusReplyShown('Status: Photo\n❤️'), '❤️');
    expect(chatPreview('Status#stabc|photo: sunset\non my way', 'ada', 'ada'), 'You: on my way');
    expect(chatPreview('Status: Photo\non my way', 'ben', 'ada'), 'on my way');
    expect(chatAlertBody('Status: Photo\non my way'), 'on my way');
    expect(chatAlertBody('Status: Photo'), 'Replied to a status');
  });
}
