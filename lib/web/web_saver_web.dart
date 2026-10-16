import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

final _blobs = <String>{};
final _urlByKey = <String, String>{};

const _dbName = 'socialsave_videos';
const _storeName = 'files';

/// Fetches the first of [urls] the page may read, saves it with the
/// browser's download, keeps a copy in IndexedDB under [storeKey] (so the
/// web Library can play it after a reload), and returns a blob URL. When no
/// URL can be read, the last one is opened as a plain browser download.
Future<String> webFetchAndSave({
  required List<String> urls,
  required String fileName,
  String? storeKey,
  Future<void>? cancelled,
  void Function(int received, int? total)? onProgress,
}) async {
  Object? lastError;
  for (final url in urls) {
    try {
      final blob = await _fetchBlob(url, cancelled: cancelled, onProgress: onProgress);
      final objectUrl = web.URL.createObjectURL(blob);
      _blobs.add(objectUrl);
      if (storeKey != null) {
        _urlByKey[storeKey] = objectUrl;
        try {
          await _put(storeKey, blob);
        } catch (_) {
          // Storage full or private mode: the browser download still has it.
        }
      }
      _clickAnchor(objectUrl, fileName, newTab: false);
      return objectUrl;
    } on _Cancelled {
      rethrow;
    } catch (error) {
      lastError = error;
    }
  }
  if (urls.isEmpty) throw StateError('No download link.');
  webOpenDownload(urls.last, fileName);
  if (lastError != null) {
    web.console.warn('SocialSave: browser download fallback ($lastError)'.toJS);
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

// ---- IndexedDB copy of each saved video --------------------------------

Future<web.IDBDatabase>? _dbFuture;

Future<web.IDBDatabase> _db() {
  return _dbFuture ??= () {
    final done = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open(_dbName, 1);
    request.onupgradeneeded = ((web.Event _) {
      final db = request.result as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_storeName)) {
        db.createObjectStore(_storeName);
      }
    }).toJS;
    request.onsuccess = ((web.Event _) {
      done.complete(request.result as web.IDBDatabase);
    }).toJS;
    request.onerror = ((web.Event _) {
      _dbFuture = null;
      done.completeError(StateError('IndexedDB unavailable'));
    }).toJS;
    return done.future;
  }();
}

Future<JSAny?> _request(web.IDBRequest request) {
  final done = Completer<JSAny?>();
  request.onsuccess = ((web.Event _) => done.complete(request.result)).toJS;
  request.onerror = ((web.Event _) => done.completeError(StateError('IndexedDB request failed'))).toJS;
  return done.future;
}

Future<void> _put(String key, web.Blob blob) async {
  final db = await _db();
  final store = db.transaction(_storeName.toJS, 'readwrite').objectStore(_storeName);
  await _request(store.put(blob, key.toJS));
}

Future<web.Blob?> _get(String key) async {
  final db = await _db();
  final store = db.transaction(_storeName.toJS, 'readonly').objectStore(_storeName);
  final result = await _request(store.get(key.toJS));
  if (result == null || !result.isA<web.Blob>()) return null;
  return result as web.Blob;
}

/// A playable URL for the video saved under [key] (this tab or IndexedDB).
Future<String?> webStoredVideoUrl(String key) async {
  final cached = _urlByKey[key];
  if (cached != null) return cached;
  try {
    final blob = await _get(key);
    if (blob == null) return null;
    final url = web.URL.createObjectURL(blob);
    _blobs.add(url);
    _urlByKey[key] = url;
    return url;
  } catch (_) {
    return null;
  }
}

Future<bool> webHasStoredVideo(String key) async {
  if (_urlByKey.containsKey(key)) return true;
  try {
    return await _get(key) != null;
  } catch (_) {
    return false;
  }
}

Future<void> webDeleteStoredVideo(String key) async {
  final url = _urlByKey.remove(key);
  if (url != null) {
    _blobs.remove(url);
    web.URL.revokeObjectURL(url);
  }
  try {
    final db = await _db();
    final store = db.transaction(_storeName.toJS, 'readwrite').objectStore(_storeName);
    await _request(store.delete(key.toJS));
  } catch (_) {}
}

/// Downloads the stored copy again (to the browser's Downloads folder).
Future<bool> webSaveStoredVideo(String key, String fileName) async {
  final url = await webStoredVideoUrl(key);
  if (url == null) return false;
  _clickAnchor(url, fileName, newTab: false);
  return true;
}

/// Web Share API: shares the stored file when the browser can, else the
/// link. Returns false when the browser has no share sheet.
Future<bool> webShare({
  required String title,
  String? url,
  String? fileKey,
  String? fileName,
}) async {
  final navigator = web.window.navigator;
  if (fileKey != null) {
    try {
      final blob = await _get(fileKey);
      if (blob != null) {
        final file = web.File(
          [blob].toJS,
          fileName ?? 'video.mp4',
          web.FilePropertyBag(type: blob.type.isEmpty ? 'video/mp4' : blob.type),
        );
        final data = web.ShareData(title: title, files: [file].toJS);
        if (navigator.canShare(data)) {
          await navigator.share(data).toDart;
          return true;
        }
      }
    } catch (_) {}
  }
  try {
    final data = web.ShareData(title: title, text: title, url: url ?? '');
    if (!navigator.canShare(data)) return false;
    await navigator.share(data).toDart;
    return true;
  } catch (_) {
    return false;
  }
}

// ---- picking and uploading files (web nearby share) ---------------------

class WebPickedFile {
  const WebPickedFile(this.handle, this.name, this.size);

  /// A web.Blob / web.File.
  final Object handle;
  final String name;
  final int size;
}

/// Opens the browser's file chooser. Call straight from a tap.
Future<WebPickedFile?> webPickFile() {
  final done = Completer<WebPickedFile?>();
  final input = web.HTMLInputElement()..type = 'file';
  input.style.display = 'none';
  web.document.body?.append(input);
  void finish(WebPickedFile? value) {
    if (!done.isCompleted) done.complete(value);
    input.remove();
  }

  input.onchange = ((web.Event _) {
    final files = input.files;
    if (files == null || files.length == 0) return finish(null);
    final file = files.item(0)!;
    finish(WebPickedFile(file, file.name, file.size));
  }).toJS;
  input.addEventListener('cancel', ((web.Event _) => finish(null)).toJS);
  input.click();
  return done.future;
}

/// The copy of a saved video in IndexedDB, as an uploadable file.
Future<WebPickedFile?> webStoredFile(String key, String name) async {
  try {
    final blob = await _get(key);
    if (blob == null) return null;
    return WebPickedFile(blob, name, blob.size);
  } catch (_) {
    return null;
  }
}

/// A small XHR helper: returns (status, body). With [upload] it posts the
/// file as multipart field "file" and reports upload progress.
Future<(int, String)> webHttp(
  String method,
  String url, {
  WebPickedFile? upload,
  void Function(int sent, int total)? onProgress,
}) {
  final done = Completer<(int, String)>();
  final xhr = web.XMLHttpRequest();
  xhr.open(method, url);
  xhr.onload = ((web.Event _) {
    if (!done.isCompleted) done.complete((xhr.status, xhr.responseText));
  }).toJS;
  xhr.onerror = ((web.Event _) {
    if (!done.isCompleted) done.complete((0, ''));
  }).toJS;
  if (upload != null) {
    xhr.upload.onprogress = ((web.ProgressEvent event) {
      onProgress?.call(event.loaded.toInt(), event.lengthComputable ? event.total.toInt() : upload.size);
    }).toJS;
    final form = web.FormData();
    form.append('file', upload.handle as web.Blob, upload.name);
    xhr.send(form);
  } else {
    xhr.send();
  }
  return done.future;
}
