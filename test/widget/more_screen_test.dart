import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_history.dart';
import 'package:social_save/features/more/more_screen.dart';

void main() {
  testWidgets('More lists chats, music and sharing with the unread badge',
      (tester) async {
    ChatHistory.unreadTotal.value = 0;
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: Scaffold(body: MoreScreen())),
      ),
    );
    expect(find.text('More'), findsOneWidget);
    expect(find.byKey(const ValueKey('more-chat')), findsOneWidget);
    expect(find.byKey(const ValueKey('more-music')), findsOneWidget);
    expect(find.byKey(const ValueKey('more-share')), findsOneWidget);
    expect(find.text('3'), findsNothing);

    ChatHistory.unreadTotal.value = 3;
    await tester.pump();
    expect(find.text('3'), findsOneWidget);
    ChatHistory.unreadTotal.value = 0;
  });
}
