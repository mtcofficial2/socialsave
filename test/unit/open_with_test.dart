import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/core/platform/open_with.dart';

void main() {
  test('Open with passes the video path, and flags are not treated as files', () {
    expect(
      openedVideoArgument([r'C:\Videos\clip.mp4']),
      r'C:\Videos\clip.mp4',
    );
    expect(
      openedVideoArgument(['--play', r'D:\Films\movie.mkv']),
      r'D:\Films\movie.mkv',
    );
    expect(openedVideoArgument(['--open', '/library']), isNull);
    expect(openedVideoArgument(['--key-log']), isNull);
  });
}
