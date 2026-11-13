import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/chat/chat_prefs.dart';
import 'package:social_save/features/chat/day_streak.dart';
import 'package:social_save/features/chat/emoji_catalog.dart';
import 'package:social_save/features/chat/emoji_text.dart';
import 'package:social_save/features/chat/link_text.dart';
import 'package:social_save/features/chat/status_fonts.dart';

void main() {
  test('frequent emojis keep the newest use first', () {
    final once = rememberEmoji(const [], '😀');
    final again = rememberEmoji([...once, '❤️'], '😀');
    expect(again.first, '😀');
    expect(again.where((item) => item == '😀').length, 1);
    expect(rememberEmoji(List<String>.filled(32, '👍'), '😂').length, 32);
  });

  test('a favorite is kept and then removed', () {
    final kept = toggleFavorite(const [], '🔥');
    expect(kept, ['🔥']);
    expect(toggleFavorite(kept, '🔥'), isEmpty);
  });

  test('emoji search matches the name', () {
    final found = searchEmojis('pizza');
    expect(found.map((item) => item.char), contains('🍕'));
    expect(searchEmojis('').length, emojiCatalog.length);
  });

  test('the first web address is kept and a video link can be downloaded', () {
    expect(firstWebUrl('see https://youtu.be/abc123.'), 'https://youtu.be/abc123');
    expect(firstWebUrl('no link here'), isNull);
    expect(linkOffersDownload('https://youtu.be/abc123'), isTrue);
    expect(linkOffersDownload('https://example.com/story'), isFalse);
  });

  test('an emoji message is bare and a sentence is not', () {
    expect(emojiOnlyText('😀'), isTrue);
    expect(emojiOnlyText('👍❤️'), isTrue);
    expect(emojiOnlyText('1️⃣'), isTrue);
    expect(emojiClusterCount('😀😂🔥'), 3);
    expect(emojiOnlySize(1), 48);
    expect(emojiOnlyText('hello 😀'), isFalse);
    expect(emojiOnlyText('ok'), isFalse);
    expect(emojiOnlyText(''), isFalse);
  });

  test('a streak grows on the next day and starts over after a gap', () {
    final monday = DateTime(2026, 11, 9);
    final first = bumpStreak(lastDay: null, count: 0, now: monday);
    expect(first.count, 1);
    expect(first.day, '2026-11-09');
    final same = bumpStreak(lastDay: first.day, count: first.count, now: monday);
    expect(same.count, 1);
    final tuesday = bumpStreak(
      lastDay: first.day,
      count: first.count,
      now: DateTime(2026, 11, 10),
    );
    expect(tuesday.count, 2);
    expect(streakLabel(2), '2-day streak');
    final later = bumpStreak(
      lastDay: tuesday.day,
      count: tuesday.count,
      now: DateTime(2026, 11, 12),
    );
    expect(later.count, 1);
    expect(
      statusListLine(views: 0, streak: 2, viewLabel: 'No views yet'),
      'Tap to see updates · No views yet · 2-day streak',
    );
  });

  test('status fonts stay a set of twenty and wifi updates start on', () {
    expect(statusFontChoices, hasLength(20));
    expect(statusFontIndex(-1), 0);
    expect(statusFontIndex(8), 8);
    expect(statusFontIndex(40), 0);
    expect(ChatPrefs.wifiUpdateValue(null), isTrue);
    expect(ChatPrefs.wifiUpdateValue(false), isFalse);
  });

  test('a page title and picture are read from the html', () {
    const html = '''
      <html><head>
      <meta property="og:title" content="A walk">
      <meta property="og:description" content="By the lake">
      <meta property="og:image" content="/cover.jpg">
      <title>Ignored</title>
      </head></html>
    ''';
    final meta = metaFromHtml('https://example.com/post', html);
    expect(meta.title, 'A walk');
    expect(meta.description, 'By the lake');
    expect(meta.image, 'https://example.com/cover.jpg');
  });
}
