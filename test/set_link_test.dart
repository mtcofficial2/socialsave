import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/core/utils/set_link.dart';
import 'package:social_save/shared/models/playlist_entry.dart';

void main() {
  test('public sets are playlists, profiles, highlights and albums', () {
    expect(isPublicSet('https://www.youtube.com/playlist?list=PLtest'), isTrue);
    expect(isPublicSet('https://www.youtube.com/watch?list=PLtest'), isTrue);
    expect(isPublicSet('https://www.youtube.com/watch?v=abcdefghijk&list=PLtest'), isFalse);
    expect(isPublicSet('https://www.youtube.com/@creator'), isTrue);
    expect(isPublicSet('https://www.youtube.com/@creator/videos'), isTrue);
    expect(isPublicSet('https://www.youtube.com/@creator/shorts'), isTrue);
    expect(isPublicSet('https://www.youtube.com/@creator/live'), isTrue);
    expect(isPublicSet('https://www.youtube.com/@creator/shorts/abc'), isFalse);
    expect(isPublicSet('https://www.youtube.com/channel/UCabcdefghijklmnop'), isTrue);
    expect(isPublicSet('https://www.youtube.com/channel/UCabcdefghijklmnop/videos'), isTrue);
    expect(isPublicSet('https://www.youtube.com/shorts/abc'), isFalse);
    expect(isPublicSet('https://www.tiktok.com/@creator'), isTrue);
    expect(isPublicSet('https://www.tiktok.com/@creator/video/123'), isFalse);
    expect(isPublicSet('https://www.instagram.com/stories/highlights/12345'), isTrue);
    expect(isPublicSet('https://www.instagram.com/reel/abc'), isFalse);
    expect(isPublicSet('https://www.facebook.com/media/set/?set=a.1'), isTrue);
    expect(isPublicSet('https://www.instagram.com/accounts/login'), isFalse);
  });

  test('channel tabs are sections and a channel root is not', () {
    expect(isChannelSection('https://www.youtube.com/@creator/videos'), isTrue);
    expect(isChannelSection('https://www.youtube.com/@creator/shorts'), isTrue);
    expect(isChannelSection('https://www.youtube.com/@creator/streams'), isTrue);
    expect(isChannelSection('https://www.youtube.com/@creator/live'), isTrue);
    expect(isChannelSection('https://www.youtube.com/channel/UCabcdefghijklmnop/videos'), isTrue);
    expect(isChannelSection('https://www.youtube.com/@creator'), isFalse);
    expect(isChannelSection('https://www.youtube.com/@creator/shorts/abc'), isFalse);
    expect(isChannelSection('https://www.youtube.com/watch?v=abcdefghijk'), isFalse);
    expect(isChannelSection('https://www.youtube.com/playlist?list=PLtest'), isFalse);
    expect(isChannelSection('https://www.tiktok.com/@creator'), isFalse);
    expect(youtubeChannelRoot('https://www.youtube.com/@creator'), 'https://www.youtube.com/@creator');
    expect(youtubeChannelRoot('https://www.youtube.com/@creator/videos'), isNull);
    expect(youtubeChannelRoot('https://www.youtube.com/watch?v=abcdefghijk'), isNull);
    expect(
      youtubeChannelRoot('https://www.youtube.com/channel/UCabcdefghijklmnop'),
      'https://www.youtube.com/channel/UCabcdefghijklmnop',
    );
    expect(youtubeChannelBase('https://www.youtube.com/@creator/shorts'), 'https://www.youtube.com/@creator');
    expect(youtubeChannelTab('https://www.youtube.com/@creator/shorts'), 'shorts');
    expect(youtubeChannelTab('https://www.youtube.com/@creator/live'), 'streams');
    expect(youtubeChannelTab('https://www.youtube.com/@creator'), isNull);
    expect(
      youtubeChannelTabUrl('https://www.youtube.com/@creator', 'shorts'),
      'https://www.youtube.com/@creator/shorts',
    );
  });

  test('shorts only opens the shorts tab', () async {
    final calls = <String>[];
    final out = await expandChannelSections(
      const [
        PlaylistEntry(title: 'Videos', url: 'https://www.youtube.com/@c/videos'),
        PlaylistEntry(title: 'Shorts', url: 'https://www.youtube.com/@c/shorts'),
      ],
      (url) async {
        calls.add(url);
        return const [PlaylistEntry(title: 'S', url: 'https://www.youtube.com/shorts/bbb')];
      },
      onlyTab: 'shorts',
    );
    expect(calls, ['https://www.youtube.com/@c/shorts']);
    expect(out.single.url, 'https://www.youtube.com/shorts/bbb');
  });

  test('channel tabs expand into videos and are not walked again', () async {
    final calls = <String>[];
    final out = await expandChannelSections(
      [
        const PlaylistEntry(title: 'Shorts', url: 'https://www.youtube.com/@c/shorts'),
        const PlaylistEntry(title: 'Videos', url: 'https://www.youtube.com/@c/videos'),
      ],
      (url) async {
        calls.add(url);
        if (url.endsWith('/videos')) {
          return const [
            PlaylistEntry(title: 'A', url: 'https://www.youtube.com/watch?v=aaa'),
            PlaylistEntry(title: 'tab again', url: 'https://www.youtube.com/@c/streams'),
          ];
        }
        return const [
          PlaylistEntry(title: 'S', url: 'https://www.youtube.com/shorts/bbb'),
          PlaylistEntry(title: 'A again', url: 'https://www.youtube.com/watch?v=aaa'),
        ];
      },
    );
    expect(calls, [
      'https://www.youtube.com/@c/videos',
      'https://www.youtube.com/@c/shorts',
    ]);
    expect(out.map((entry) => entry.url).toList(), [
      'https://www.youtube.com/watch?v=aaa',
      'https://www.youtube.com/shorts/bbb',
    ]);
  });

  test('a channel page opens its video tabs once', () async {
    final calls = <String>[];
    final out = await expandChannelSections(
      const [PlaylistEntry(title: 'Channel', url: 'https://www.youtube.com/@c')],
      (url) async {
        calls.add(url);
        if (url.endsWith('/videos')) {
          return const [PlaylistEntry(title: 'A', url: 'https://youtu.be/abc')];
        }
        return const [];
      },
    );
    expect(calls, [
      'https://www.youtube.com/@c/videos',
      'https://www.youtube.com/@c/shorts',
      'https://www.youtube.com/@c/streams',
    ]);
    expect(out.single.url, 'https://youtu.be/abc');
  });

  test('a normal playlist is left as it is', () async {
    final items = [
      for (var i = 0; i < 3; i++) PlaylistEntry(title: '$i', url: 'https://www.youtube.com/watch?v=v$i'),
    ];
    var calls = 0;
    final out = await expandChannelSections(items, (url) async {
      calls++;
      return const [];
    });
    expect(calls, 0);
    expect(out, items);
  });

  test('expanded videos stop at 40 and a silent tab is skipped', () async {
    final capped = await expandChannelSections(
      const [PlaylistEntry(title: 'Videos', url: 'https://www.youtube.com/@c/videos')],
      (url) async => [
        for (var i = 0; i < 50; i++) PlaylistEntry(title: '$i', url: 'https://www.youtube.com/watch?v=$i'),
      ],
    );
    expect(capped, hasLength(40));

    final empty = await expandChannelSections(
      const [PlaylistEntry(title: 'Videos', url: 'https://www.youtube.com/@c/videos')],
      (url) => Completer<List<PlaylistEntry>>().future,
      tabTimeout: const Duration(milliseconds: 30),
    );
    expect(empty, isEmpty);
  });
}
