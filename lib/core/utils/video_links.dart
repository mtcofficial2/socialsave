import 'package:social_save/core/utils/platform_detector.dart';
import 'package:social_save/core/utils/set_link.dart';
import 'package:social_save/core/utils/url_validator.dart';
import 'package:social_save/shared/models/social_platform.dart';

final _urlInText = RegExp(r'https?://[^\s<>"]+', caseSensitive: false);
final _trailingJunk = RegExp(r'[.,;:)\]]+$');

/// Every supported public link in [raw], in the order they appear.
/// The same address is kept once. A public set is included.
List<String> videoLinksIn(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return const [];
  const validator = UrlValidator();
  const detector = PlatformDetector();
  final out = <String>[];
  final seen = <String>{};
  void keep(String piece) {
    final found = validator.validate(piece);
    if (!found.isValid || found.normalized == null) return;
    final url = found.normalized.toString();
    if (detector.detect(url) == SocialPlatform.unknown) return;
    if (seen.add(url)) out.add(url);
  }

  final matches = _urlInText.allMatches(text).toList();
  if (matches.isEmpty) {
    keep(text);
    return out;
  }
  for (final match in matches) {
    final piece = match.group(0)!.replaceFirst(_trailingJunk, '');
    keep(piece);
  }
  return out;
}

/// The first supported public link in [raw], or null.
String? videoLinkIn(String? raw) {
  final links = videoLinksIn(raw);
  return links.isEmpty ? null : links.first;
}

/// Video links that should start together. One link, and a public set,
/// stay on the single-link path.
List<String> linksToSaveTogether(String? raw) {
  final videos = [
    for (final url in videoLinksIn(raw))
      if (!isPublicSet(url)) url,
  ];
  if (videos.length < 2) return const [];
  return videos;
}
