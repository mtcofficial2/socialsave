import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/player/resume_position.dart';

void main() {
  test('resume key stays the same for the same file across calls', () {
    const path = r'C:\Movies\SocialSave\clip.mp4';
    final first = resumeStorageKey(isPreview: false, filePath: path);
    final second = resumeStorageKey(isPreview: false, filePath: path);
    expect(first, second);
    expect(first, 'player.pos.v2.file.$path');
    expect(first, isNot(contains('${path.hashCode}')));
  });

  test('preview streams and empty files are not remembered', () {
    expect(
      resumeStorageKey(isPreview: true, filePath: '/tmp/a.mp4'),
      isNull,
    );
    expect(resumeStorageKey(isPreview: false), isNull);
    expect(
      resumeStorageKey(isPreview: false, deviceId: '42'),
      'player.pos.v2.device.42',
    );
  });

  test('a real stop is stored and the ending is not', () {
    expect(
      positionToStore(positionMs: 12500, durationMs: 60000, completed: false),
      12500,
    );
    expect(
      positionToStore(positionMs: 400, durationMs: 60000, completed: false),
      isNull,
    );
    expect(
      positionToStore(positionMs: 59000, durationMs: 60000, completed: false),
      isNull,
    );
    expect(
      positionToStore(positionMs: 12500, durationMs: 60000, completed: true),
      isNull,
    );
  });

  test('saved position is applied only when it is inside the video', () {
    expect(shouldResume(18000, 0), isTrue);
    expect(shouldResume(18000, 60000), isTrue);
    expect(shouldResume(500, 60000), isFalse);
    expect(shouldResume(59000, 60000), isFalse);
    expect(shouldResume(null, 60000), isFalse);
  });

  test('resume clock reads as minutes and seconds', () {
    expect(formatResumeClock(const Duration(minutes: 1, seconds: 5)), '1:05');
    expect(formatResumeClock(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
  });
}
