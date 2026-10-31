import 'dart:convert';
import 'dart:io';

import 'package:social_save/features/chat/chat_link_rules.dart';

/// Reads a small public page on this device. Fails quietly.
Future<({String title, String image})?> fetchChatPage(String url) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 6);
  try {
    var current = Uri.tryParse(url);
    for (var hop = 0; hop < 3; hop++) {
      if (!chatLinkAllowed(current)) return null;
      final request = await client.getUrl(current!).timeout(const Duration(seconds: 6));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'SocialSave');
      final response = await request.close().timeout(const Duration(seconds: 6));
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null || location.isEmpty) return null;
        current = current.resolve(location);
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return null;
      }
      final type = response.headers.contentType?.mimeType ?? '';
      if (type.isNotEmpty && !type.contains('html') && type != 'text/plain') {
        await response.drain<void>();
        return null;
      }
      final bytes = await _readCap(response, 48 * 1024);
      final html = utf8.decode(bytes, allowMalformed: true);
      return _readMeta(current, html);
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<List<int>> _readCap(HttpClientResponse response, int cap) async {
  final out = <int>[];
  await for (final chunk in response) {
    final room = cap - out.length;
    if (room <= 0) break;
    if (chunk.length <= room) {
      out.addAll(chunk);
    } else {
      out.addAll(chunk.take(room));
      break;
    }
  }
  return out;
}

({String title, String image})? _readMeta(Uri page, String html) {
  final title = _meta(html, 'og:title') ?? _title(html);
  final imageRaw = _meta(html, 'og:image') ?? '';
  var image = '';
  if (imageRaw.isNotEmpty) {
    final resolved = page.resolve(imageRaw);
    if (chatLinkAllowed(resolved)) image = resolved.toString();
  }
  final clean = title?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
  if (clean.isEmpty && image.isEmpty) return null;
  return (title: clean, image: image);
}

String? _meta(String html, String key) {
  final propertyFirst = RegExp(
    'property=["\']${RegExp.escape(key)}["\'][^>]*content=["\']([^"\']+)["\']',
    caseSensitive: false,
  );
  final contentFirst = RegExp(
    'content=["\']([^"\']+)["\'][^>]*property=["\']${RegExp.escape(key)}["\']',
    caseSensitive: false,
  );
  final match = propertyFirst.firstMatch(html) ?? contentFirst.firstMatch(html);
  final value = match?.group(1)?.trim();
  if (value == null || value.isEmpty) return null;
  return _decode(value);
}

String? _title(String html) {
  final match = RegExp(r'<title[^>]*>([^<]+)</title>', caseSensitive: false).firstMatch(html);
  final value = match?.group(1)?.trim();
  if (value == null || value.isEmpty) return null;
  return _decode(value);
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
