import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_ui.dart';

void main() {
  testWidgets('tapping a written username does not also tap the page', (tester) async {
    String? opened;
    var steps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (_) => steps++,
            child: Center(
              child: ChatTapText(
                text: 'meet @Ada there',
                color: const Color(0xFF111111),
                onUsername: (name) => opened = name,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('@Ada'));
    await tester.pump();
    expect(opened, 'ada');
    expect(steps, 0);

    final box = tester.getRect(find.byType(ChatTapText));
    await tester.tapAt(box.centerLeft + const Offset(8, 0));
    await tester.pump();
    expect(steps, 1);
  });

  testWidgets('a link in the message stays a link', (tester) async {
    String? link;
    String? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatTapText(
            text: 'see https://example.com/a and @ben',
            links: const ['https://example.com/a'],
            color: const Color(0xFF111111),
            linkColor: const Color(0xFF027EB5),
            onLink: (url) => link = url,
            onUsername: (name) => opened = name,
          ),
        ),
      ),
    );

    await tester.tap(find.text('https://example.com/a'));
    await tester.tap(find.text('@ben'));
    await tester.pump();
    expect(link, 'https://example.com/a');
    expect(opened, 'ben');
  });
}
