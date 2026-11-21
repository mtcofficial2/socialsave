import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/features/chat/chat_voice.dart';

ChatMessage _msg(int id, String text, {String status = '', String name = 'me', DateTime? at, String kind = '', int voiceMs = 0, String voice = ''}) {
  return ChatMessage(
    id: id,
    from: name,
    name: name,
    text: text,
    links: const [],
    at: at ?? DateTime(2026, 11, 21, 22),
    status: status,
    pendingKind: kind,
    voiceMs: voiceMs,
    voice: voice,
  );
}

void main() {
  test('voice levels round-trip into real bars', () {
    final take = [for (var i = 0; i < 200; i++) i < 100 ? 0.1 : 1.0];
    final code = encodeVoiceLevels(take);
    expect(code.length, 48);
    expect(RegExp(r'^[0-9]+$').hasMatch(code), isTrue);
    expect(code.startsWith('1'), isTrue);
    expect(code.endsWith('9'), isTrue);
    final bars = decodeVoiceLevels(code, 24);
    expect(bars, hasLength(24));
    expect(bars.first, lessThan(bars.last));
    expect(bars.every((b) => b >= 0.2 && b <= 1.0), isTrue);
  });

  test('short takes keep one digit per sample and bad codes fall back', () {
    expect(encodeVoiceLevels(const [0.0, 0.5, 1.0]), '059');
    expect(encodeVoiceLevels(const []), '');
    expect(decodeVoiceLevels('12a', 10), isEmpty);
    expect(voiceBarsFor(levels: '', seed: 'v1', count: 12), voiceBars('v1', 12));
    expect(voiceBarsFor(levels: '9999', seed: 'v1', count: 4), everyElement(1.0));
  });

  test('queued messages resend oldest first and delivered ones are matched', () {
    final early = _msg(-1, 'first', status: 'queued', at: DateTime(2026, 11, 21, 22, 0));
    final late = _msg(-2, 'second', status: 'queued', at: DateTime(2026, 11, 21, 22, 1));
    final failed = _msg(-3, 'rejected', status: 'failed');
    final order = chatResendOrder([late, failed, early]);
    expect(order.map((m) => m.id), [-1, -2]);

    final server = _msg(10, 'first', at: DateTime(2026, 11, 21, 22, 0, 30));
    expect(chatAlreadyDelivered(early, [server, early, late], me: 'me'), isTrue);
    expect(chatAlreadyDelivered(late, [server, early, late], me: 'me'), isFalse);
    final other = _msg(11, 'second', name: 'ben', at: DateTime(2026, 11, 21, 22, 1));
    expect(chatAlreadyDelivered(late, [other], me: 'me'), isFalse);
  });

  test('queued shows as its own tick and is read out', () {
    expect(chatTick(mine: true, id: -1, peerDelivered: 0, peerRead: 0, status: 'queued'), 'queued');
    final label = chatBubbleSemantics(mine: true, sender: 'me', time: '10:00 PM', tick: 'queued', voice: true, voiceMs: 4200);
    expect(label, 'You, voice note, 4 seconds, 10:00 PM, waiting for network');
    expect(chatBubbleSemantics(mine: false, sender: 'ben', time: '9:00 AM', photo: true), 'ben, photo, 9:00 AM');
  });

  test('ChatMessage keeps voice levels through JSON', () {
    final m = ChatMessage.fromJson({'id': 3, 'name': 'me', 'text': 'Voice message', 'at': 1, 'voice': 'v', 'voiceMs': 1200, 'voiceLevels': '0369'});
    expect(m.voiceLevels, '0369');
    expect(m.toJson()['voiceLevels'], '0369');
    expect(ChatMessage.fromJson({'id': 4, 'name': 'me', 'text': 'hi', 'at': 1}).toJson().containsKey('voiceLevels'), isFalse);
  });
}
