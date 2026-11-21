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
                  ? const [Color(0xFF0A1020), Color(0xFF070B14), Color(0xFF0C1428)]
                  : const [Color(0xFF0B1220), Color(0xFF070B14), Color(0xFF10182C)]
              : const [Color(0xFFF4F7FC), Color(0xFFE7F0FA), Color(0xFFF7F4EF)],
        ),
      ),
      child: Stack(
        children: [
          _Glow(top: wide ? -200 : -120, left: wide ? 80 : -90, size: wide ? 620 : 360, color: const Color(0x883B82F6)),
          _Glow(top: wide ? -60 : 120, right: wide ? -40 : -110, size: wide ? 540 : 400, color: const Color(0x7738BDF8)),
          _Glow(bottom: wide ? -160 : -80, left: wide ? 200 : -40, size: wide ? 480 : 360, color: const Color(0x664C6EF5)),
          _Glow(bottom: 20, right: -60, size: wide ? 380 : 300, color: const Color(0x552563EB)),
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
                  color.withValues(alpha: dark ? 0.16 : color.a * 0.72),
                  color.withValues(alpha: dark ? 0.06 : color.a * 0.28),
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
