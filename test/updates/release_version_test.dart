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

  test('the Android app is the apk asset, not the Windows zip', () {
    final assets = [
      {
        'name': 'SocialSave-Windows-1.0.20.zip',
        'browser_download_url': 'https://example.com/SocialSave-Windows-1.0.20.zip',
      },
      {
        'name': 'SocialSave.apk',
        'browser_download_url': 'https://example.com/SocialSave.apk',
      },
    ];
    expect(androidReleaseApk(assets), 'https://example.com/SocialSave.apk');
    expect(
      androidReleaseApk([
        {
          'name': 'SocialSave-1.0.20.apk',
          'browser_download_url': 'https://example.com/other.apk',
        },
      ]),
      'https://example.com/other.apk',
    );
    expect(androidReleaseApk([{'name': 'notes.txt', 'browser_download_url': 'https://example.com/n.txt'}]), isNull);
  });
}
