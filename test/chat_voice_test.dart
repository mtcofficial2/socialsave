import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_voice.dart';

void main() {
  test('voice bars stay in range and stay the same for an id', () {
    final first = voiceBars('v123', 24);
    final again = voiceBars('v123', 24);
    expect(again, first);
    expect(first, hasLength(24));
    expect(first.every((bar) => bar >= 0.2 && bar <= 1), isTrue);
    expect(voiceBars('other', 24), isNot(first));
  });

  testWidgets('recording bar and sent voice note lay out', (tester) async {
    final view = ValueNotifier<ChatRecView>((ms: 4200, levels: const [0.2, 0.8, 0.5, 0.9], paused: false));
    addTearDown(view.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: ChatRecordingBar(view: view, onDelete: () {}, onSend: () {}, onPause: () {}),
          ),
        ),
      ),
    );
    expect(find.text('0:04'), findsOneWidget);
    expect(find.byIcon(Icons.delete_rounded), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 328,
              child: ChatVoiceBubble(
                message: ChatMessage(
                  id: 1,
                  from: 'ada',
                  name: 'Ada',
                  text: 'Voice message',
                  links: const [],
                  at: DateTime(2026, 10, 31, 18),
                  voice: 'v123',
                  voiceMs: 12500,
                  voiceType: 'm4a',
                ),
                api: ChatApi(baseUrl: 'https://example.invalid'),
                mine: true,
                dark: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    expect(find.text('0:12'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
