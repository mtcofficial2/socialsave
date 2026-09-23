import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/core/utils/platform_detector.dart';
import 'package:social_save/shared/models/social_platform.dart';

void main() {
  const detector = PlatformDetector();

  test('detects each supported host', () {
    expect(detector.detect('https://www.tiktok.com/@a/video/1'), SocialPlatform.tiktok);
    expect(detector.detect('https://instagram.com/p/abc'), SocialPlatform.instagram);
    expect(detector.detect('https://facebook.com/watch/?v=1'), SocialPlatform.facebook);
    expect(detector.detect('https://x.com/user/status/1'), SocialPlatform.x);
    expect(detector.detect('https://twitter.com/user/status/1'), SocialPlatform.x);
    expect(detector.detect('https://youtu.be/abc'), SocialPlatform.youtube);
    expect(detector.detect('https://reddit.com/r/videos/comments/abc'), SocialPlatform.reddit);
    expect(detector.detect('https://pinterest.com/pin/1'), SocialPlatform.pinterest);
    expect(
      detector.detect('https://cdn.example.com/film.mp4'),
      SocialPlatform.direct,
    );
  });

  test('other public websites are accepted as web videos', () {
    expect(detector.detect('https://example.com/watch'), SocialPlatform.web);
    expect(detector.detect('https://vimeo.com/123'), SocialPlatform.web);
  });

  test('text that is not a URL stays unknown', () {
    expect(detector.detect('not a link'), SocialPlatform.unknown);
  });
}
