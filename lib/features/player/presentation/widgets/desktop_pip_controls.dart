import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'package:social_save/shared/widgets/premium_glass.dart';

/// Hover controls for the Windows mini player: drag anywhere to move,
/// play/pause, a thin seek bar, back to the full app, and close.
class DesktopPipControls extends StatefulWidget {
  const DesktopPipControls({
    super.key,
    required this.player,
    required this.onExpand,
    required this.onClose,
  });

  final Player player;
  final VoidCallback onExpand;
  final VoidCallback onClose;

  @override
  State<DesktopPipControls> createState() => _DesktopPipControlsState();
}

class _DesktopPipControlsState extends State<DesktopPipControls> {
  bool _hover = false;
  Timer? _hide;

  void _show() {
    _hide?.cancel();
    if (!_hover) setState(() => _hover = true);
    _hide = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _hover = false);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  Widget _btn(IconData icon, String tip, VoidCallback onTap) => IconButton(
        tooltip: tip,
        onPressed: onTap,
        iconSize: 20,
        visualDensity: VisualDensity.compact,
        color: Colors.white.withValues(alpha: 0.92),
        icon: Icon(icon),
      );

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    return MouseRegion(
      onHover: (_) => _show(),
      onEnter: (_) => _show(),
      onExit: (_) => setState(() => _hover = false),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Drag the mini player around; double-click goes back to the app.
          DragToMoveArea(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onDoubleTap: widget.onExpand,
              child: const SizedBox.expand(),
            ),
          ),
          IgnorePointer(
            ignoring: !_hover,
            child: AnimatedOpacity(
              opacity: _hover ? 1 : 0,
              duration: const Duration(milliseconds: 160),
              child: Theme(
                data: ThemeData.dark(),
                child: Stack(
                  children: [
                    Positioned(
                      top: 6,
                      right: 6,
                      child: PremiumGlass(
                        radius: 999,
                        level: GlassLevel.thin,
                        lifted: false,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _btn(Icons.open_in_full_rounded, 'Back to the app (Esc)', widget.onExpand),
                            _btn(Icons.close_rounded, 'Close', widget.onClose),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 8,
                      right: 8,
                      bottom: 6,
                      child: PremiumGlass(
                        radius: 999,
                        level: GlassLevel.thin,
                        lifted: false,
                        child: Row(
                          children: [
                            StreamBuilder<bool>(
                              stream: p.stream.playing,
                              initialData: p.state.playing,
                              builder: (context, s) => _btn(
                                s.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                'Play or pause (Space)',
                                () => unawaited(p.playOrPause()),
                              ),
                            ),
                            Expanded(
                              child: StreamBuilder<Duration>(
                                stream: p.stream.position,
                                initialData: p.state.position,
                                builder: (context, s) {
                                  final total = p.state.duration.inMilliseconds;
                                  final pos = (s.data ?? Duration.zero).inMilliseconds;
                                  final v = total <= 0 ? 0.0 : (pos / total).clamp(0.0, 1.0);
                                  return SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 3,
                                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                                      overlayShape: SliderComponentShape.noOverlay,
                                      activeTrackColor: Colors.white.withValues(alpha: 0.92),
                                      inactiveTrackColor: Colors.white.withValues(alpha: 0.25),
                                      thumbColor: Colors.white,
                                    ),
                                    child: Slider(
                                      value: v,
                                      onChanged: total <= 0
                                          ? null
                                          : (x) => unawaited(p.seek(Duration(milliseconds: (x * total).round()))),
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 10),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}