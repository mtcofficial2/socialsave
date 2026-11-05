import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/updates/release_version.dart';

void main() {
  test('an open app looks again without a force stop', () {
    final start = DateTime(2026, 11, 5, 19);
    expect(updateLookDue(last: null, now: start), isTrue);
    expect(updateLookDue(last: start, now: start.add(const Duration(seconds: 19)), force: true), isFalse);
    expect(updateLookDue(last: start, now: start.add(updateLookSoonest), force: true), isTrue);
    expect(updateLookDue(last: start, now: start.add(const Duration(seconds: 59))), isFalse);
    expect(updateLookDue(last: start, now: start.add(updateLookEvery)), isTrue);
    expect(updateLookDue(last: start.add(const Duration(minutes: 9)), now: start), isFalse);
  });

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
