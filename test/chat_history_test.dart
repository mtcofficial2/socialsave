import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_history.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ss-hist');
    ChatHistory.rootOverride = root;
    ChatHistory.debugReset();
  });

  tearDown(() {
    ChatHistory.rootOverride = null;
    ChatHistory.debugReset();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  ChatMessage message({
    required int id,
    String text = 'Hello',
    String status = '',
    String name = 'ben',
    Uint8List? bytes,
    String pendingKind = '',
  }) {
    return ChatMessage(
      id: id,
      from: name,
      name: name,
      text: text,
      links: const [],
      at: DateTime.fromMillisecondsSinceEpoch(1700000000000 + id),
      status: status,
      localBytes: bytes,
      pendingKind: pendingKind,
    );
  }

  test('chats and messages reopen from this phone', () async {
    const me = 'ada';
    await ChatHistory.saveThreads(me, [
      ChatThreadSummary(
        id: 'abc123',
        username: 'ben',
        lastText: 'Hello',
        lastAt: DateTime.fromMillisecondsSinceEpoch(1700000000001),
        lastId: 1,
        lastFrom: 'ben',
        unread: 1,
        lastSeen: DateTime.fromMillisecondsSinceEpoch(1700000001000),
        online: true,
      ),
    ]);
    await ChatHistory.merge(
      username: me,
      threadId: 'abc123',
      incoming: [message(id: 1)],
      delivered: 1,
      read: 0,
      seen: DateTime.fromMillisecondsSinceEpoch(1700000001000),
    );
    ChatHistory.debugReset();

    final threads = await ChatHistory.threads(me);
    expect(threads, hasLength(1));
    expect(threads.single.username, 'ben');
    expect(threads.single.lastText, 'Hello');
    expect(threads.single.online, isFalse);
    expect(threads.single.lastSeen, isNotNull);

    final log = await ChatHistory.log(me, 'abc123');
    expect(log, isNotNull);
    expect(log!.messages.single.text, 'Hello');
    expect(log.delivered, 1);
    expect(log.seen, isNotNull);
  });

  test('a waiting message stays and can be tried again', () async {
    const me = 'ada';
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    await ChatHistory.saveLog(
      username: me,
      threadId: 'abc123',
      messages: [
        message(id: 4, text: 'Saved'),
        message(
          id: -2,
          text: 'On my way',
          status: 'sending',
          name: me,
        ),
        message(
          id: -3,
          text: 'Photo',
          status: 'sending',
          name: me,
          bytes: bytes,
          pendingKind: 'photo',
        ),
      ],
      delivered: 4,
      read: 4,
      photoRev: 0,
    );
    ChatHistory.debugReset();

    final log = await ChatHistory.log(me, 'abc123');
    expect(log, isNotNull);
    expect(log!.messages.map((item) => item.text), [
      'Saved',
      'On my way',
      'Photo',
    ]);
    expect(log.messages[1].status, 'failed');
    expect(log.messages[2].status, 'failed');
    expect(log.messages[2].localBytes, bytes);
  });

  test('older messages stay when a newer page arrives', () async {
    const me = 'ada';
    await ChatHistory.merge(
      username: me,
      threadId: 'abc123',
      incoming: [message(id: 1, text: 'First')],
    );
    await ChatHistory.saveLog(
      username: me,
      threadId: 'abc123',
      messages: [message(id: 2, text: 'Second', name: me)],
      delivered: 1,
      read: 0,
      photoRev: 0,
    );
    ChatHistory.debugReset();

    final log = await ChatHistory.log(me, 'abc123');
    expect(log!.messages.map((item) => item.text), ['First', 'Second']);
  });

  test('a live message is kept once and clears the waiting copy', () async {
    const me = 'ada';
    await ChatHistory.saveThreads(me, [
      const ChatThreadSummary(id: 'abc123', username: 'ben', unread: 2),
    ]);
    await ChatHistory.saveLog(
      username: me,
      threadId: 'abc123',
      messages: [
        message(id: -1, text: 'Ping', status: 'sending', name: 'ben'),
      ],
      delivered: 0,
      read: 0,
      photoRev: 0,
    );
    await ChatHistory.remember(
      me: me,
      threadId: 'abc123',
      message: message(id: 8, text: 'Ping', name: 'ben'),
      open: true,
    );
    await ChatHistory.remember(
      me: me,
      threadId: 'abc123',
      message: message(id: 8, text: 'Ping', name: 'ben'),
      open: true,
    );
    ChatHistory.debugReset();

    final log = await ChatHistory.log(me, 'abc123');
    expect(log!.messages, hasLength(1));
    expect(log.messages.single.id, 8);
    final threads = await ChatHistory.threads(me);
    expect(threads.single.unread, 2);
    expect(threads.single.lastId, 8);
  });

  test('a deleted message does not come back', () async {
    const me = 'ada';
    await ChatHistory.merge(
      username: me,
      threadId: 'abc123',
      incoming: [
        message(id: 1, text: 'First'),
        message(id: 2, text: 'Second'),
      ],
    );
    await ChatHistory.saveThreads(me, [
      ChatThreadSummary(
        id: 'abc123',
        username: 'ben',
        lastText: 'Second',
        lastId: 2,
        lastFrom: 'ben',
      ),
    ]);
    await ChatHistory.hide(username: me, threadId: 'abc123', ids: [2]);
    await ChatHistory.merge(
      username: me,
      threadId: 'abc123',
      incoming: [message(id: 2, text: 'Second'), message(id: 3, text: 'Third')],
      removed: const [2],
    );
    await ChatHistory.remember(
      me: me,
      threadId: 'abc123',
      message: message(id: 2, text: 'Second'),
    );
    await ChatHistory.saveLog(
      username: me,
      threadId: 'abc123',
      messages: [
        message(id: 1, text: 'First'),
        message(id: 2, text: 'Second'),
        message(id: 3, text: 'Third'),
      ],
      delivered: 3,
      read: 0,
      photoRev: 0,
    );
    ChatHistory.debugReset();

    final log = await ChatHistory.log(me, 'abc123');
    expect(log!.messages.map((item) => item.id), [1, 3]);
    final threads = await ChatHistory.threads(me);
    expect(threads.single.lastId, 1);
    expect(threads.single.lastText, 'First');
  });
}
