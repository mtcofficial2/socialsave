import 'package:flutter/material.dart';

/// Faint doodles on the chat canvas. No bitmap and no extra theme.
class ChatWallpaper extends StatelessWidget {
  const ChatWallpaper({super.key, required this.dark, this.pattern = false});

  final bool dark;

  /// Off leaves the canvas plain. The pattern is a Settings choice.
  final bool pattern;

  @override
  Widget build(BuildContext context) {
    if (!pattern) return const SizedBox.expand();
    return IgnorePointer(
      child: CustomPaint(
        painter: _Doodles(dark: dark),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _Doodles extends CustomPainter {
  const _Doodles({required this.dark});

  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.15
      ..color = (dark ? const Color(0xFFE9EDEF) : const Color(0xFF6B5E53)).withValues(alpha: dark ? 0.028 : 0.038);
    const step = 80.0;
    for (var y = 0.0; y < size.height + step; y += step) {
      final shift = ((y / step).floor() % 2 == 0) ? 0.0 : step / 2;
      for (var x = -step; x < size.width + step; x += step) {
        final ox = x + shift;
        canvas.drawCircle(Offset(ox + 18, y + 20), 5.5, paint);
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(ox + 34, y + 40, 18, 12), const Radius.circular(3)),
          paint,
        );
        canvas.drawLine(Offset(ox + 8, y + 58), Offset(ox + 22, y + 58), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_Doodles oldDelegate) => oldDelegate.dark != dark;
}
