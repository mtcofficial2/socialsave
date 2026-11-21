import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/downloader/follow_creator.dart';

void main() {
  test('the creator notice names them and says a video is ready', () {
    expect(creatorNoticeTitle('  Ada  '), 'Ada');
    expect(creatorNoticeTitle(''), 'Creator');
    expect(creatorNoticeTitle('   '), 'Creator');
    expect(creatorNoticeBody(1), 'A new video is ready to download.');
    expect(creatorNoticeBody(3), '3 new videos are ready to download.');
  });
}
