import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/core/utils/together.dart';
import 'package:social_save/core/utils/video_links.dart';

void main() {
  test('several links are kept, in order, once each', () {
    const text = '''
Look:
https://www.youtube.com/watch?v=abcdefghijk
https://www.tiktok.com/@creator/video/123,
https://youtu.be/abcdefghijk
https://www.youtube.com/watch?v=abcdefghijk
''';
    expect(videoLinksIn(text), [
      'https://www.youtube.com/watch?v=abcdefghijk',
      'https://www.tiktok.com/@creator/video/123',
      'https://youtu.be/abcdefghijk',
    ]);
    expect(videoLinkIn(text), 'https://www.youtube.com/watch?v=abcdefghijk');
    expect(linksToSaveTogether(text), [
      'https://www.youtube.com/watch?v=abcdefghijk',
      'https://www.tiktok.com/@creator/video/123',
      'https://youtu.be/abcdefghijk',
    ]);
  });

  test('one link and a public set stay on the single-link path', () {
    expect(
      linksToSaveTogether('https://www.youtube.com/watch?v=abcdefghijk'),
      isEmpty,
    );
    expect(
      linksToSaveTogether('https://www.youtube.com/playlist?list=PLtest'),
      isEmpty,
    );
    expect(
      linksToSaveTogether(
        'https://www.youtube.com/playlist?list=PLtest\n'
        'https://www.youtube.com/watch?v=abcdefghijk',
      ),
      isEmpty,
    );
  });

  test('several links start together', () async {
    var active = 0;
    var peak = 0;
    final started = <int>[];
    final seen = Completer<void>();
    final wave = Completer<void>();
    final task = runTogether(List<int>.generate(6, (i) => i), (item) async {
      started.add(item);
      active++;
      if (active > peak) peak = active;
      if (started.length == saveAtOnce && !seen.isCompleted) seen.complete();
      await wave.future;
      active--;
    });
    await seen.future;
    expect(peak, saveAtOnce);
    expect(List<int>.of(started), [0, 1, 2, 3]);
    wave.complete();
    await task;
    expect(started.length, 6);
  });
}
