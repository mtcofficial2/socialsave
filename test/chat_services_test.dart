import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_prefs.dart';
import 'package:social_save/features/chat/chat_status_screen.dart';

void main() {
  test('quiet hours can pass midnight', () {
    expect(ChatPrefs.minutesQuiet(22 * 60, 7 * 60, 23 * 60), isTrue);
    expect(ChatPrefs.minutesQuiet(22 * 60, 7 * 60, 6 * 60), isTrue);
    expect(ChatPrefs.minutesQuiet(22 * 60, 7 * 60, 12 * 60), isFalse);
    expect(ChatPrefs.minutesQuiet(9 * 60, 17 * 60, 9 * 60), isTrue);
    expect(ChatPrefs.minutesQuiet(9 * 60, 17 * 60, 17 * 60), isFalse);
    expect(ChatPrefs.minutesQuiet(8 * 60, 8 * 60, 8 * 60), isFalse);
  });

  test('mentions stay quiet unless the name is in the message', () {
    ChatPrefs.notifyMode.clear();
    expect(
      ChatPrefs.showsNotice(
        threadId: 'g1',
        group: true,
        text: 'hello',
        me: 'ada',
      ),
      isTrue,
    );
    ChatPrefs.notifyMode['g1'] = 'mentions';
    expect(
      ChatPrefs.showsNotice(
        threadId: 'g1',
        group: true,
        text: 'hello',
        me: 'ada',
      ),
      isFalse,
    );
    expect(
      ChatPrefs.showsNotice(
        threadId: 'g1',
        group: true,
        text: 'hello @ada',
        me: '@Ada',
      ),
      isTrue,
    );
    expect(
      ChatPrefs.showsNotice(
        threadId: 't1',
        group: false,
        text: 'hello',
        me: 'ada',
      ),
      isTrue,
    );
    ChatPrefs.notifyMode.clear();
  });

  test('a poll, contact, place, and call survive a local save', () {
    final message = ChatMessage(
      id: 4,
      from: 'u',
      name: 'ada',
      text: 'Contact: Ada',
      links: const [],
      at: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      poll: const ChatPoll(question: 'Lunch?', choices: ['Yes', 'No']),
      card: const ChatCard(name: 'Ada', phone: '256700000111'),
      place: const ChatPlace(lat: 0.3476, lng: 32.5825, label: 'Kampala'),
      call: 'c1',
      callMs: 75,
    );
    final again = ChatMessage.fromJson(message.toJson());
    expect(again.poll?.question, 'Lunch?');
    expect(again.poll?.choices, ['Yes', 'No']);
    expect(again.card?.phone, '256700000111');
    expect(again.place?.link, 'https://maps.google.com/?q=0.34760,32.58250');
    expect(again.call, 'c1');
    expect(again.callMs, 75);
  });

  test('a live call and a saved call both keep the caller name', () {
    final live = ChatCallRecord.fromJson({
      'id': 'c1',
      'thread': 't1',
      'state': 'ringing',
      'from': 'ada',
      'fromId': 'u1',
    });
    final saved = ChatCallRecord.fromJson({
      'id': 'c1',
      'thread': 't1',
      'state': 'missed',
      'from': 'u1',
      'fromName': 'ada',
    });
    expect(live.fromName, 'ada');
    expect(live.fromId, 'u1');
    expect(saved.fromName, 'ada');
    expect(saved.fromId, 'u1');
    expect(live.live, isTrue);
    expect(saved.live, isFalse);
  });

  test('a trimmed call offer gets its closing line back', () {
    const offer = 'v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n';
    final trimmed = callSdp(offer.trim());
    expect(trimmed.endsWith('\r\n'), isTrue);
    expect(trimmed.contains('m=audio 9'), isTrue);
    expect(callSdp(trimmed), trimmed);
    expect(callSdp('not an offer'), isEmpty);
    expect(callSdp(r'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n').contains('m=audio'), isTrue);
  });

  test('a ringing call from someone else is the one to answer', () {
    final rows = [
      const ChatCallRecord(id: 'c1', thread: 't1', state: 'ringing', fromName: 'ada'),
      const ChatCallRecord(id: 'c2', thread: 't2', state: 'ringing', fromName: 'ben'),
    ];
    expect(incomingRing(rows, 'ada')?.id, 'c2');
    expect(incomingRing(rows, '@Ada')?.id, 'c2');
    expect(
      incomingRing(
        const [
          ChatCallRecord(id: 'c1', thread: 't1', state: 'ringing', fromName: 'ada'),
        ],
        'ada',
      ),
      isNull,
    );
    expect(incomingRing(const [], 'ada'), isNull);
  });

  test('a call this phone is in ends when the other person declines', () {
    const live = ChatCallRecord(id: 'c1', thread: 't1', state: 'ringing', fromName: 'ada');
    expect(watchedCallFinished(const [live], 'c1'), isFalse);
    expect(
      watchedCallFinished(
        const [ChatCallRecord(id: 'c1', thread: 't1', state: 'declined', fromName: 'ada')],
        'c1',
      ),
      isTrue,
    );
    expect(watchedCallFinished(const [], 'c1'), isTrue);
    expect(watchedCallFinished(const [live], ''), isFalse);
    expect(callIsOver('ended'), isTrue);
    expect(callIsOver('missed'), isTrue);
    expect(callIsOver('cancelled'), isTrue);
    expect(callIsOver('active'), isFalse);
    expect(callExitLabel('declined'), 'Declined');
    expect(callExitLabel('missed'), 'Missed call');
    expect(callExitLabel('cancelled'), 'Cancelled');
    expect(callExitLabel('ended'), 'Call ended');
  });

  test('a status view count is words and stays with the author', () {
    expect(statusViewLabel(0), 'No views yet');
    expect(statusViewLabel(1), '1 view');
    expect(statusViewLabel(4), '4 views');
    final note = ChatStatusNote.fromJson({
      'id': 'st1',
      'name': 'ada',
      'text': 'out',
      'at': 1,
      'views': ['ben', 'cam'],
    });
    expect(note.views, ['ben', 'cam']);
    final hidden = ChatStatusNote.fromJson({
      'id': 'st1',
      'name': 'ada',
      'text': 'out',
      'at': 1,
    });
    expect(hidden.views, isEmpty);
  });
}
