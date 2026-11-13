import 'package:url_launcher/url_launcher.dart';

/// Opens [url] in the device browser. Returns false when the address is not http.
Future<bool> openWebLink(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
    return false;
  }
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}
