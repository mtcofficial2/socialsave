import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

abstract class WebVideoHandle {
  void play();
  void pause();
  void restart();
}

class _Handle implements WebVideoHandle {
  _Handle(this.video);

  final web.HTMLVideoElement video;

  @override
  void play() => video.play().toDart.catchError((Object _) => null);

  @override
  void pause() => video.pause();

  @override
  void restart() {
    video.currentTime = 0;
    play();
  }
}

/// The browser's own video element with its controls: real frames, full
/// screen, picture-in-picture and keyboard support come from the browser.
class WebVideoView extends StatefulWidget {
  const WebVideoView({super.key, required this.url, this.onEnded, this.onReady, this.onNoPicture});

  final String url;
  final VoidCallback? onEnded;
  final void Function(WebVideoHandle handle)? onReady;
  final VoidCallback? onNoPicture;

  @override
  State<WebVideoView> createState() => _WebVideoViewState();
}

class _WebVideoViewState extends State<WebVideoView> {
  static var _next = 0;
  late final String _viewType;
  web.HTMLVideoElement? _video;

  @override
  void initState() {
    super.initState();
    _viewType = 'socialsave-video-${_next++}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) {
      final video = web.HTMLVideoElement()
        ..src = widget.url
        ..controls = true
        ..autoplay = true
        ..playsInline = true
        ..preload = 'auto';
      video.style
        ..width = '100%'
        ..height = '100%'
        ..backgroundColor = 'black'
        ..objectFit = 'contain';
      video.onended = ((web.Event _) => widget.onEnded?.call()).toJS;
      video.onloadeddata = ((web.Event _) {
        // Plays but no frames: a codec this browser can't decode (H.265).
        if (video.videoWidth == 0) widget.onNoPicture?.call();
      }).toJS;
      _video = video;
      widget.onReady?.call(_Handle(video));
      return video;
    });
  }

  @override
  void dispose() {
    final video = _video;
    if (video != null) {
      video.pause();
      video.removeAttribute('src');
      video.load();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => HtmlElementView(viewType: _viewType);
}
