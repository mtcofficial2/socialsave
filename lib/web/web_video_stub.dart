import 'package:flutter/widgets.dart';

class WebVideoView extends StatelessWidget {
  const WebVideoView({super.key, required this.url, this.onEnded, this.onReady});

  final String url;
  final VoidCallback? onEnded;
  final void Function(WebVideoHandle handle)? onReady;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

abstract class WebVideoHandle {
  void play();
  void pause();
  void restart();
}
