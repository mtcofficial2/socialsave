import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/core/notifications/notification_service.dart';

NotificationResponse _tap({
  String? actionId,
  String? input,
  String? payload,
  Map<String, dynamic> data = const {},
}) {
  return NotificationResponse(
    notificationResponseType:
        NotificationResponseType.selectedNotificationAction,
    actionId: actionId,
    input: input,
    payload: payload,
    data: data,
  );
}

void main() {
  test('an Android reply keeps the chat and the typed text', () {
    final parts = chatNotificationReplyOf(
      _tap(actionId: 'reply', input: '  hello  ', payload: 'chat|abc|Ada'),
    );
    expect(parts.$1, 'chat|abc|Ada');
    expect(parts.$2, 'hello');
  });

  test('a Windows reply reads the text from the reply box', () {
    final parts = chatNotificationReplyOf(
      _tap(
        actionId: 'chat|abc|Ada',
        payload: 'chat|abc|Ada',
        data: {'reply': '  see you '},
      ),
    );
    expect(parts.$1, 'chat|abc|Ada');
    expect(parts.$2, 'see you');
  });

  test('a reply does not open the chat', () {
    expect(
      chatNotificationOpensChat(
        _tap(actionId: 'reply', input: 'hello', payload: 'chat|abc|Ada'),
      ),
      isFalse,
    );
    expect(
      chatNotificationOpensChat(
        _tap(
          actionId: 'chat|abc|Ada',
          payload: 'chat|abc|Ada',
          data: {'reply': 'see you'},
        ),
      ),
      isFalse,
    );
  });

  test('opening the chat without text is not a reply', () {
    final parts = chatNotificationReplyOf(
      _tap(payload: 'chat|abc|Ada', input: '   '),
    );
    expect(parts.$1, 'chat|abc|Ada');
    expect(parts.$2, isNull);
    expect(
      chatNotificationOpensChat(_tap(payload: 'chat|abc|Ada')),
      isTrue,
    );
  });

  test('other notifications are left alone', () {
    final parts = chatNotificationReplyOf(
      _tap(actionId: 'download|https://example.com', input: 'nope'),
    );
    expect(parts.$1, isNull);
    expect(parts.$2, 'nope');
  });

  test('a blank or unrelated reply is not sent', () async {
    await sendChatNotificationReply('chat|abc|Ada', '   ');
    await sendChatNotificationReply('usbshare|open', 'hello');
    await sendChatNotificationReply('chat| |Ada', 'hello');
  });
}
