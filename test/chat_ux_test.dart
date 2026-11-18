import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_ux.dart';

ChatMessage _message({
  required int id,
  String name = 'ada',
  String text = '',
  DateTime? at,
  String status = '',
  String photo = '',
  String voice = '',
  String songName = '',
  String pendingKind = '',
  String replyText = '',
  String fileName = '',
  String file = '',
  bool clip = false,
  int fileSize = 0,
}) {
  return ChatMessage(
    id: id,
    from: name,
    name: name,
    text: text,
    links: const [],
    at: at ?? DateTime(2026, 1, 1, 12),
    status: status,
    photo: photo,
    voice: voice,
    songName: songName,
    pendingKind: pendingKind,
    replyText: replyText,
    fileName: fileName,
    file: file,
    clip: clip,
    fileSize: fileSize,
  );
}

void main() {
  test('photo sets hide bare followers and keep a caption or quote', () {
    final start = DateTime(2026, 1, 1, 12);
    final messages = [
      _message(id: 1, photo: 'a', text: 'Picnic', at: start),
      _message(id: 2, photo: 'b', text: 'Photo', at: start.add(const Duration(seconds: 20))),
      _message(id: 3, photo: 'c', text: 'Photo', at: start.add(const Duration(seconds: 40))),
      _message(id: 4, photo: 'd', text: 'The lake', at: start.add(const Duration(seconds: 50))),
      _message(
        id: 5,
        photo: 'e',
        text: 'Photo',
        replyText: 'Picnic',
        at: start.add(const Duration(seconds: 55)),
      ),
      _message(id: 6, name: 'ben', photo: 'f', text: 'Photo', at: start.add(const Duration(seconds: 56))),
      _message(id: 7, photo: 'g', text: 'Photo', at: start.add(const Duration(seconds: 130))),
    ];
    expect(chatPhotoFollowers(messages), {2, 3});
    expect(chatPhotoAlbum(messages, messages.first).map((item) => item.id), [1, 2, 3]);
    expect(chatPhotoAlbum(messages, messages[3]).map((item) => item.id), [4]);
  });

  test('search hits include text, quotes, songs, and file names', () {
    final messages = [
      _message(id: 1, text: 'Hello Ada'),
      _message(id: 2, replyText: 'Hello Ada'),
      _message(id: 3, songName: 'Ada song'),
      _message(id: 4, fileName: 'ada.txt', file: 'f1'),
      _message(id: 5, text: 'Nothing'),
    ];
    expect(chatSearchHitIds(messages, 'ada'), [1, 2, 3, 4]);
    expect(chatSearchHitIds(messages, '  '), isEmpty);
  });

  test('mention query reads the @name at the caret', () {
    expect(chatMentionQuery('hi @ad', 6), 'ad');
    expect(chatMentionQuery('hi @', 4), '');
    expect(chatMentionQuery('email me@ada.com', 13), isNull);
    expect(chatMentionQuery('@', 1), '');
    expect(chatMentionQuery('hi @ada', 2), isNull);
  });

  test('failed send is the newest outgoing failure that is not older', () {
    final at = DateTime(2026, 1, 2, 9);
    final messages = [
      _message(id: -2, name: 'ada', status: 'failed', text: 'old', at: at.subtract(const Duration(minutes: 5))),
      _message(id: -1, name: 'ada', status: 'failed', text: 'new', at: at),
      _message(id: 3, name: 'ben', text: 'ok', at: at),
    ];
    expect(chatHasFailedSend(messages, 'ada', at), isTrue);
    expect(
      chatHasFailedSend(messages, 'ada', at.add(const Duration(minutes: 1))),
      isFalse,
    );
    expect(chatHasFailedSend(messages, 'ben', null), isFalse);
  });

  test('pinned chats sort ahead of newer unpinned chats', () {
    final older = ChatThreadSummary(
      id: 'a',
      username: 'ada',
      pinned: true,
      lastAt: DateTime(2026, 1, 1),
    );
    final newer = ChatThreadSummary(
      id: 'b',
      username: 'ben',
      lastAt: DateTime(2026, 1, 2),
    );
    expect(chatPinCompare(older, newer), lessThan(0));
    final marked = chatWithListFlags(newer, pinned: false, marked: true);
    expect(marked.unread, 1);
    expect(marked.marked, isTrue);
  });

  test('byte labels, file kinds, and forward rules', () {
    expect(chatByteLabel(12), '12 B');
    expect(chatByteLabel(2048), '2 KB');
    expect(chatIsDocumentName('notes.PDF'), isTrue);
    expect(chatIsDocumentName('photo.jpg'), isFalse);
    expect(chatIsClipName('clip.mp4'), isTrue);
    expect(chatIsClipName('notes.pdf'), isFalse);
    expect(chatCanForward(_message(id: 1, text: 'Hello')), isTrue);
    expect(chatCanForward(_message(id: 2, text: 'Photo', photo: 'p')), isFalse);
    expect(chatCanForward(_message(id: 3, text: 'Voice', voice: 'v')), isFalse);
    expect(chatCanForward(_message(id: 4, text: 'Doc', file: 'f', fileName: 'a.pdf')), isFalse);
    expect(chatCanForward(_message(id: 5, text: ' ')), isFalse);
  });
}
