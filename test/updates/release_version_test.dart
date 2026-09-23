import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/updates/release_version.dart';

void main() {
  test('a newer GitHub tag is an update and the same tag is not', () {
    final update = newerRelease(
      current: '1.0.0',
      tag: 'v1.0.1',
      apkUrl: 'https://github.com/mtcofficial2/socialsave/releases/download/v1.0.1/SocialSave.apk',
    );
    expect(update?.version, '1.0.1');
    expect(
      update?.downloadUrl.toString(),
      'https://github.com/mtcofficial2/socialsave/releases/download/v1.0.1/SocialSave.apk',
    );
    expect(
      newerRelease(current: '1.0.1+2', tag: 'v1.0.1', apkUrl: 'https://example.com/a.apk'),
      isNull,
    );
    expect(newerRelease(current: '1.1.0', tag: 'v1.0.9', apkUrl: 'https://example.com/a.apk'), isNull);
  });
}
