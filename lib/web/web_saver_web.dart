import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

final _blobs = <String>{};

/// Fetches the first of [urls] that the browser is allowed to read, saves it
/// with the browser's download, and returns a blob URL for playback. When no
/// URL can be read (the video host sends no CORS headers), the last URL is
/// opened as a normal browser download and that URL is returned instead.
Future<String> webFetchAndSave({
  required List<String> urls,
  required String fileName,
  Future<void>? cancelled,
  void Function(int received, int? total)? onProgress,
}) async {
  Object? lastError;
  for (final url in urls) {
    try {
      final blob = await _fetchBlob(url, cancelled: cancelled, onProgress: onProgress);
      final objectUrl = web.URL.createObjectURL(blob);
      _blobs.add(objectUrl);
      _clickAnchor(objectUrl, fileName, newTab: false);
      return objectUrl;
    } on _Cancelled {
      rethrow;
    } catch (error) {
      lastError = error;
    }
  }
  if (urls.isEmpty) throw StateError('No download link.');
  // The host does not allow reading the file from a page. Let the browser
  // download it directly (the server's link sends it as an attachment).
  webOpenDownload(urls.last, fileName);
  if (lastError != null) {
    // ignore: avoid_print
    print('web save fell back to a browser download: $lastError');
  }
  return urls.last;
}

class _Cancelled implements Exception {
  @override
  String toString() => 'cancelled';
}

Future<web.Blob> _fetchBlob(
  String url, {
  Future<void>? cancelled,
  void Function(int received, int? total)? onProgress,
}) {
  final done = Completer<web.Blob>();
  final xhr = web.XMLHttpRequest();
  xhr.open('GET', url);
  xhr.responseType = 'blob';
  xhr.onprogress = ((web.ProgressEvent event) {
    onProgress?.call(
      event.loaded.toInt(),
      event.lengthComputable ? event.total.toInt() : null,
    );
  }).toJS;
  xhr.onload = ((web.Event _) {
    if (done.isCompleted) return;
    final status = xhr.status;
    if (status >= 200 && status < 300 && xhr.response != null) {
      done.complete(xhr.response! as web.Blob);
    } else {
      done.completeError(StateError('HTTP $status'));
    }
  }).toJS;
  xhr.onerror = ((web.Event _) {
    if (!done.isCompleted) done.completeError(StateError('blocked or offline'));
  }).toJS;
  xhr.onabort = ((web.Event _) {
    if (!done.isCompleted) done.completeError(_Cancelled());
  }).toJS;
  unawaited(cancelled?.then((_) {
    if (!done.isCompleted) xhr.abort();
  }));
  xhr.send();
  return done.future;
}

void _clickAnchor(String url, String fileName, {required bool newTab}) {
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName
    ..rel = 'noopener';
  if (newTab) anchor.target = '_blank';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
}

void webOpenDownload(String url, String fileName) {
  _clickAnchor(url, fileName, newTab: true);
}

void webOpenTab(String url) {
  web.window.open(url, '_blank', 'noopener');
}

bool webCanPlay(String url) => _blobs.contains(url);
