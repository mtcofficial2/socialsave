import 'dart:convert';

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
    expect(callUsesFullScreen(outgoing: true, status: 'ringing'), isFalse);
    expect(callUsesFullScreen(outgoing: true, status: 'active'), isTrue);
    expect(callUsesFullScreen(outgoing: false, status: 'ringing'), isTrue);
    expect(callUsesFullScreen(outgoing: false, status: 'active'), isTrue);
    expect(
      callPickedUpElsewhere(outgoing: false, answering: false, status: 'ringing'),
      isTrue,
    );
    expect(
      callPickedUpElsewhere(outgoing: true, answering: false, status: 'ringing'),
      isFalse,
    );
    expect(
      callPickedUpElsewhere(outgoing: false, answering: true, status: 'ringing'),
      isFalse,
    );
    expect(
      callPickedUpElsewhere(outgoing: false, answering: false, status: 'active'),
      isFalse,
    );
  });

  test('a PC candidate uses the Wi-Fi address instead of a hidden name', () {
    const hidden = 'candidate:1 1 udp 2122260223 pc-host.local 53917 typ host';
    final encoded = jsonEncode({
      'candidate': hidden,
      'sdpMid': '0',
      'sdpMLineIndex': 0,
    });
    final swapped = jsonDecode(callCandidateForPeer(encoded, '192.168.1.40')) as Map;
    expect(swapped['candidate'], contains('192.168.1.40'));
    expect(swapped['candidate'], isNot(contains('.local')));
    expect(callCandidateForPeer(encoded, '8.8.8.8'), encoded);
    expect(callCandidateForPeer(encoded, null), encoded);
    expect(callCandidateForPeer(encoded, '100.64.0.1'), encoded);
    expect(callLanIpUsable('10.0.0.8'), isTrue);
    expect(callLanIpUsable('172.16.0.2'), isTrue);
    expect(callLanIpUsable('172.32.0.2'), isFalse);
    const sdp = 'v=0\r\n'
        'a=candidate:1 1 udp 2122260223 pc-host.local 53917 typ host\r\n'
        'a=candidate:2 1 udp 1686052607 203.0.113.8 20000 typ srflx\r\n';
    final ready = callSdpForPeer(sdp, '10.1.2.3');
    expect(ready, contains('10.1.2.3 53917'));
    expect(ready, contains('203.0.113.8 20000'));
    expect(ready, isNot(contains('.local')));
    expect(callSdpForPeer(sdp, '203.0.113.8'), sdp);
    final bulky = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n${List.filled(300, 'a=candidate:1 1 udp 1 192.168.0.2 9 typ host\r\n').join()}';
    expect(bulky.length > 10000, isTrue);
    final sent = callSdpToSend(bulky, null);
    expect(sent.startsWith('v=0'), isTrue);
    expect(sent.contains('m=audio'), isTrue);
    expect(sent.contains('a=candidate'), isFalse);
    const shortOffer = 'v=0\r\na=candidate:1 1 udp 1 1.2.3.4 9 typ host\r\n';
    expect(callSdpToSend(shortOffer, null), shortOffer);
    expect(
      callRingShouldReset(currentId: 'c1', eventId: 'c1', status: 'active', answering: false),
      isFalse,
    );
    expect(
      callRingShouldReset(currentId: 'c1', eventId: 'c1', status: 'ringing', answering: true),
      isFalse,
    );
    expect(
      callRingShouldReset(currentId: 'c1', eventId: 'c1', status: 'ringing', answering: false),
      isTrue,
    );
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
    final older = ChatStatusNote(
      id: 'old',
      name: 'Ada',
      text: 'earlier',
      at: DateTime.fromMillisecondsSinceEpoch(1),
      views: const ['ben'],
    );
    final newer = ChatStatusNote(
      id: 'new',
      name: '@ada',
      text: 'later',
      at: DateTime.fromMillisecondsSinceEpoch(5),
      views: const ['ben', 'cam'],
    );
    expect(ownStatusViews([older, newer, note], 'ada'), 2);
    expect(ownStatusViews(const [], 'ada'), isNull);
    expect(ownStatusViews([newer], ''), isNull);
  });
}
