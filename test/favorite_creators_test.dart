import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/home/favorite_creators.dart';

void main() {
  test('a saved creator keeps a portrait and drops a video thumb', () {
    final people = FavoriteCreator.decodeList(
      jsonEncode([
        {
          'url': 'https://www.youtube.com/@creator',
          'name': 'Ada - Videos',
          'platform': 'youtube',
          'avatar': 'https://i.ytimg.com/vi/abc/hqdefault.jpg',
          'checked': true,
        },
        {
          'url': 'https://www.tiktok.com/@ada',
          'name': 'Ada',
          'platform': 'tiktok',
          'avatar': 'https://p16-sign.tiktokcdn.com/avatar.jpeg',
        },
        {'url': '', 'name': 'Skip'},
      ]),
    );

    expect(people, hasLength(2));
    expect(people[0].name, 'Ada');
    expect(people[0].avatarUrl, isNull);
    expect(people[0].checked, isTrue);
    expect(people[1].avatarUrl, 'https://p16-sign.tiktokcdn.com/avatar.jpeg');
    expect(people[1].name, 'Ada');
  });
}
