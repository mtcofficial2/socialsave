import 'package:social_save/core/utils/platform_detector.dart';
import 'package:social_save/shared/models/social_platform.dart';

final _webUrl = RegExp(r'https?://[^\s<>"]+', caseSensitive: false);

/// The first http or https address in [text], without a trailing period.
String? firstWebUrl(String text) {
  final match = _webUrl.firstMatch(text);
  if (match == null) return null;
  var raw = match.group(0) ?? '';
  while (raw.endsWith('.') || raw.endsWith(',') || raw.endsWith(')') || raw.endsWith(']')) {
    raw = raw.substring(0, raw.length - 1);
  }
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return uri.toString();
}

/// True when Social Save already knows this address as a video it can try to save.
bool linkOffersDownload(String url) {
  final platform = const PlatformDetector().detect(url);
  return platform != SocialPlatform.unknown && platform != SocialPlatform.web;
}

class LinkMeta {
  const LinkMeta({
    required this.url,
    required this.host,
    required this.title,
    required this.description,
    required this.image,
  });

  final String url;
  final String host;
  final String title;
  final String description;
  final String image;

  static LinkMeta bare(String url) {
    final uri = Uri.tryParse(url);
    return LinkMeta(
      url: url,
      host: uri?.host ?? url,
      title: uri?.host ?? url,
      description: '',
      image: '',
    );
  }
}

/// Reads Open Graph tags, then the page title, from [html].
LinkMeta metaFromHtml(String url, String html) {
  final bare = LinkMeta.bare(url);
  final title = _meta(html, 'og:title') ?? _titleTag(html) ?? bare.title;
  final description = _meta(html, 'og:description') ?? _meta(html, 'description') ?? '';
  final image = _absolute(url, _meta(html, 'og:image') ?? '');
  return LinkMeta(
    url: url,
    host: bare.host,
    title: _decode(title).trim().isEmpty ? bare.host : _decode(title).trim(),
    description: _decode(description).trim(),
    image: image,
  );
}

String? _meta(String html, String key) {
  final patterns = <RegExp>[
    RegExp('property=["\']$key["\'][^>]*content=["\']([^"\']*)', caseSensitive: false),
    RegExp('content=["\']([^"\']*)["\'][^>]*property=["\']$key["\']', caseSensitive: false),
    RegExp('name=["\']$key["\'][^>]*content=["\']([^"\']*)', caseSensitive: false),
    RegExp('content=["\']([^"\']*)["\'][^>]*name=["\']$key["\']', caseSensitive: false),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(html);
    final value = match?.group(1)?.trim() ?? '';
    if (value.isNotEmpty) return value;
  }
  return null;
}

String? _titleTag(String html) {
  final match = RegExp(r'<title[^>]*>([^<]+)</title>', caseSensitive: false).firstMatch(html);
  return match?.group(1)?.trim();
}

String _absolute(String page, String image) {
  final clean = image.trim();
  if (clean.isEmpty) return '';
  final resolved = Uri.tryParse(page)?.resolve(clean);
  if (resolved == null) return '';
  if (resolved.scheme != 'http' && resolved.scheme != 'https') return '';
  return resolved.toString();
}

String _decode(String value) {
  return value
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ');
}
