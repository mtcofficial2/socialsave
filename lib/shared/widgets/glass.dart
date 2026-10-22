import 'package:flutter/material.dart';
import 'package:social_save/shared/widgets/liquid_glass.dart';
import 'package:social_save/shared/widgets/premium_glass.dart';

export 'package:social_save/shared/widgets/premium_glass.dart';

/// Wallpaper the glass surfaces frost over.
class GlassBackground extends StatelessWidget {
  const GlassBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final wide = MediaQuery.sizeOf(context).width >= 840;
    GlassGrain.ensure();
    // Drawn once and reused: nothing in here animates.
    return RepaintBoundary(
      child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? wide
                  ? const [Color(0xFF101217), Color(0xFF0A0B0E), Color(0xFF0C1014)]
                  : const [Color(0xFF0E1015), Color(0xFF0A0B0E), Color(0xFF0D1216)]
              : const [Color(0xFFF2F5FA), Color(0xFFEAF0F7), Color(0xFFF6F2EC)],
        ),
      ),
      child: Stack(
        children: [
          _Glow(top: wide ? -200 : -120, left: wide ? 120 : -90, size: wide ? 640 : 380, color: const Color(0xAA5EEAD4)),
          _Glow(top: wide ? -80 : 140, right: wide ? 0 : -120, size: wide ? 560 : 420, color: const Color(0x9993C5FD)),
          _Glow(bottom: wide ? -140 : -90, left: wide ? 240 : -60, size: wide ? 520 : 400, color: const Color(0x88A5F3FC)),
          _Glow(bottom: 40, right: -80, size: wide ? 400 : 320, color: const Color(0x88C4B5FD)),
        ],
      ),
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
        child: SizedBox(
          width: size,
          height: size,
          // A radial fade is far cheaper than a blurred box shadow.
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  color.withValues(alpha: dark ? 0.30 : color.a),
                  color.withValues(alpha: dark ? 0.12 : color.a * 0.45),
                  color.withValues(alpha: 0),
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
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
    // 1.0.49: one premium glass for every panel. Lists keep blur off so
    // scrolling stays smooth; they get the same tint, rim and shadow.
    return PremiumGlass(
      radius: borderRadius,
      blur: blur,
      padding: padding,
      lifted: blur,
      child: child,
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
    this.onTap,
  });

  final Widget? child;
  final Clip clipBehavior;
  final EdgeInsetsGeometry? margin;
  final bool blur;

  /// When set, the card squashes while held (GlassPress).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    Widget glass = Glass(
      blur: blur,
      child: child ?? const SizedBox.shrink(),
    );
    if (onTap != null) glass = GlassPress(onTap: onTap!, child: glass);
    if (margin == null) return glass;
    return Padding(padding: margin!, child: glass);
  }
}
