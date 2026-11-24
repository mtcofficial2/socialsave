import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_call.dart';

void main() {
  final now = DateTime(2026, 11, 24, 12);

  test('TURN servers from the API are kept with their credentials', () {
    final parsed = chatIceFromJson({
      'ttl': 86400,
      'iceServers': [
        {'urls': ['stun:stun.cloudflare.com:3478']},
        {
          'urls': [
            'turn:turn.cloudflare.com:3478?transport=udp',
            'turns:turn.cloudflare.com:443?transport=tcp',
            'http://not-ice',
          ],
          'username': 'u',
          'credential': 'p',
        },
      ],
    }, now);
    expect(parsed.servers, hasLength(2));
    expect(parsed.servers[1]['username'], 'u');
    expect(parsed.servers[1]['credential'], 'p');
    expect((parsed.servers[1]['urls'] as List), hasLength(2));
    expect(chatIceHasRelay(parsed.servers), isTrue);
    expect(parsed.until, now.add(const Duration(seconds: 86400 - 600)));
  });

  test('an empty or broken reply falls back to STUN for a short while', () {
    final parsed = chatIceFromJson({'iceServers': 'nope'}, now);
    expect(parsed.servers, chatDefaultIceServers);
    expect(chatIceHasRelay(parsed.servers), isFalse);
    expect(parsed.until, now.add(const Duration(minutes: 10)));
  });

  test('the peer config carries the relay servers', () {
    final config = chatCallConfig([
      {'urls': ['turn:t:3478'], 'username': 'a', 'credential': 'b'},
    ]);
    expect(config['iceTransportPolicy'], 'all');
    expect((config['iceServers'] as List).single['username'], 'a');
    expect(chatCallConfig(const [])['iceServers'], chatDefaultIceServers);
  });

  test('relay candidates survive the long-offer trim', () {
    const relay = 'a=candidate:1 1 udp 41885439 104.30.1.2 50000 typ relay raddr 0.0.0.0 rport 0';
    const srflx = 'a=candidate:2 1 udp 1677729535 41.210.1.2 40000 typ srflx raddr 0.0.0.0 rport 0';
    expect(callCandidateKeep(relay, null), isTrue);
    expect(callCandidateKeep(srflx, null), isTrue);
  });

  test('an answered call without audio says so', () {
    expect(callAudioWaitLine(const Duration(seconds: 3)), 'Connecting audio…');
    expect(callAudioWaitLine(const Duration(seconds: 15)), contains('Weak connection'));
  });
}
