import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_alert_policy.dart';

void main() {
  test('a dormant app still checks for messages', () {
    for (final life in [
      null,
      AppLifecycleState.resumed,
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      expect(chatInboxCheckRuns(life), isTrue, reason: '$life');
    }
  });

  test('a locked phone or hidden window is not someone sitting in the chat', () {
    expect(
      chatUserIsHere(life: AppLifecycleState.resumed, screenOn: true),
      isTrue,
    );
    expect(
      chatUserIsHere(life: null, screenOn: true),
      isTrue,
    );
    expect(
      chatUserIsHere(life: AppLifecycleState.resumed, screenOn: false),
      isFalse,
    );
    expect(
      chatUserIsHere(life: AppLifecycleState.paused, screenOn: true),
      isFalse,
    );
    expect(
      chatUserIsHere(life: AppLifecycleState.hidden, screenOn: true),
      isFalse,
    );
    expect(
      chatUserIsHere(life: AppLifecycleState.inactive, screenOn: false),
      isFalse,
    );
    expect(
      chatUserIsHere(life: AppLifecycleState.detached, screenOn: false),
      isFalse,
    );
  });
}
