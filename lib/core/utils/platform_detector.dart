import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/shared/models/social_platform.dart';

class PlatformDetector {
  const PlatformDetector();

  SocialPlatform detect(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || uri.host.isEmpty) {
      return SocialPlatform.unknown;
    }
    return detectUri(uri);
  }

  SocialPlatform detectUri(Uri uri) {
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');

    if (_matches(host, const [
      'tiktok.com',
      'vm.tiktok.com',
      'vt.tiktok.com',
      'm.tiktok.com',
    ])) {
      return SocialPlatform.tiktok;
    }
    if (_matches(host, const ['instagram.com', 'instagr.am'])) {
      return SocialPlatform.instagram;
    }
    if (_matches(host, const ['facebook.com', 'fb.com', 'fb.watch', 'm.facebook.com'])) {
      return SocialPlatform.facebook;
    }
    if (_matches(host, const ['twitter.com', 'x.com', 'mobile.twitter.com'])) {
      return SocialPlatform.x;
    }
    if (_matches(host, const [
      'youtube.com',
      'm.youtube.com',
      'youtu.be',
      'youtube-nocookie.com',
      'music.youtube.com',
    ])) {
      return SocialPlatform.youtube;
    }
    if (_matches(host, const ['reddit.com', 'old.reddit.com', 'v.redd.it'])) {
      return SocialPlatform.reddit;
    }
    if (_matches(host, const ['pinterest.com', 'pin.it'])) {
      return SocialPlatform.pinterest;
    }
    if (_looksLikeDirectVideo(uri)) {
      return SocialPlatform.direct;
    }
    return SocialPlatform.unknown;
  }

  bool _looksLikeDirectVideo(Uri uri) {
    final path = uri.path.toLowerCase();
    return AppConstants.allowedVideoExtensions.any(
      (ext) => path.endsWith('.$ext'),
    );
  }

  bool _matches(String host, List<String> candidates) {
    for (final candidate in candidates) {
      if (host == candidate || host.endsWith('.$candidate')) {
        return true;
      }
    }
    return false;
  }
}
