import 'dart:ui';

import 'package:flutter/material.dart';

/// Wallpaper the glass surfaces frost over.
class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xFF121A24), Color(0xFF0A1016), Color(0xFF102028)]
              : const [Color(0xFFF5FAFF), Color(0xFFEEF3F7), Color(0xFFF7F4EF)],
        ),
      ),
      child: const Stack(
        children: [
          _Glow(top: -90, left: -50, size: 280, color: Color(0x665EEAD4)),
          _Glow(top: 180, right: -80, size: 320, color: Color(0x5593C5FD)),
          _Glow(bottom: -40, left: -20, size: 300, color: Color(0x44A5F3FC)),
          _Glow(bottom: 120, right: -30, size: 220, color: Color(0x33C4B5FD)),
        ],
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({
    required this.size,
    required this.color,
    this.top,
    this.left,
    this.right,
    this.bottom,
  });

  final double size;
  final Color color;
  final double? top;
  final double? left;
  final double? right;
  final double? bottom;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Positioned(
      top: top,
      left: left,
      right: right,
      bottom: bottom,
      child: IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: dark ? 0.22 : color.a),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: dark ? 0.28 : 0.55),
                blurRadius: 80,
                spreadRadius: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Frosted panel. [blur] is for the tab bar and the main paste card.
/// Lists use the same rim and tint without a backdrop blur, so scrolling stays smooth.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.borderRadius = 28,
    this.padding,
    this.blur = false,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry? padding;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(borderRadius);
    final tint = dark
        ? const [Color(0xCC1C2633), Color(0x99141C28)]
        : const [Color(0xD9FFFFFF), Color(0xA6FFFFFF)];
    final panel = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: tint,
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: dark ? 0.16 : 0.72),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.28 : 0.06),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );

    return ClipRRect(
      borderRadius: radius,
      child: blur
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: panel,
            )
          : panel,
    );
  }
}

/// Drop-in replacement for [Card] with the glass surface.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    this.child,
    this.clipBehavior = Clip.antiAlias,
    this.margin,
    this.blur = false,
  });

  final Widget? child;
  final Clip clipBehavior;
  final EdgeInsetsGeometry? margin;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final glass = Glass(
      blur: blur,
      child: child ?? const SizedBox.shrink(),
    );
    if (margin == null) return glass;
    return Padding(padding: margin!, child: glass);
  }
}
