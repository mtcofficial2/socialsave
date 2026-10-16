// Saving a finished download from the browser build.
//
// The phone and PC apps write files with dart:io; a browser cannot, so the
// web build fetches the video into a blob (with progress), hands it to the
// browser's own download, and keeps the blob URL so it can be played in this
// tab. Native builds get the stub, which is never called there.
export 'web_saver_stub.dart' if (dart.library.js_interop) 'web_saver_web.dart';
