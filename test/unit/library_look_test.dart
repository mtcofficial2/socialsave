import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/library/presentation/library_look.dart';

void main() {
  test('library clock pads minutes and seconds', () {
    expect(libraryClock(45), '00:45');
    expect(libraryClock(102), '01:42');
    expect(libraryClock(3661), '1:01:01');
  });

  test('library size and date follow the library cards', () {
    expect(librarySize(0), '');
    expect(librarySize(18.4 * 1024 * 1024 ~/ 1), '18.4 MB');
    final now = DateTime(2026, 10, 15, 15);
    expect(libraryWhen(DateTime(2026, 10, 15, 9), now: now), 'Today');
    expect(libraryWhen(DateTime(2026, 10, 14, 9), now: now), 'Yesterday');
    expect(libraryWhen(DateTime(2026, 10, 12), now: now), 'Oct 12');
    expect(libraryWhen(null), '');
  });

  test('platform badge uses the file name and skips a stray x', () {
    expect(libraryPlatformBadge('Epic TikTok drone'), 'TikTok');
    expect(libraryPlatformBadge('watch?v=youtube'), 'YouTube');
    expect(libraryPlatformBadge('instagram reel'), 'Instagram');
    expect(libraryPlatformBadge('a remix'), isNull);
    expect(libraryPlatformBadge('clip from x'), 'X');
  });
}
