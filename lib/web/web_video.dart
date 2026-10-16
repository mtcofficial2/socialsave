// A plain browser <video> for the web player (native builds get a stub).
export 'web_video_stub.dart' if (dart.library.js_interop) 'web_video_web.dart';
