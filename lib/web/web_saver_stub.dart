/// Native builds save with dart:io; these are only used by the web build.
Future<String> webFetchAndSave({
  required List<String> urls,
  required String fileName,
  Future<void>? cancelled,
  void Function(int received, int? total)? onProgress,
}) {
  throw UnsupportedError('Only used by the web build.');
}

/// Asks the browser to download [url] (or open it in a new tab).
void webOpenDownload(String url, String fileName) {}

/// Opens [url] in a new browser tab.
void webOpenTab(String url) {}

/// True when [url] is a blob made in this tab, so it can still be played.
bool webCanPlay(String url) => false;
