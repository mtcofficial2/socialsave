// Native builds never call these; the web build gets web_saver_web.dart.
class WebSaveResult {
  const WebSaveResult({required this.url, required this.stored, required this.fetched});

  final String url;
  final bool stored;
  final bool fetched;
}

Future<WebSaveResult> webFetchAndSave({
  required List<String> urls,
  required String fileName,
  String? storeKey,
  Future<void>? cancelled,
  void Function(int received, int? total)? onProgress,
}) {
  throw UnsupportedError('Only used by the web build.');
}

void webOpenDownload(String url, String fileName) {}

void webOpenTab(String url) {}

bool webCanPlay(String url) => false;

Future<String?> webStoredVideoUrl(String key) async => null;

Future<bool> webHasStoredVideo(String key) async => false;

Future<void> webDeleteStoredVideo(String key) async {}

Future<bool> webSaveStoredVideo(String key, String fileName) async => false;

Future<bool> webShare({required String title, String? url, String? fileKey, String? fileName}) async => false;

class WebPickedFile {
  const WebPickedFile(this.handle, this.name, this.size);

  final Object handle;
  final String name;
  final int size;
}

Future<WebPickedFile?> webPickFile() async => null;

Future<WebPickedFile?> webStoredFile(String key, String name) async => null;

Future<(int, String)> webHttp(
  String method,
  String url, {
  WebPickedFile? upload,
  void Function(int sent, int total)? onProgress,
}) async =>
    (0, '');
