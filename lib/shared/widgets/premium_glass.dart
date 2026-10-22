import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:social_save/shared/widgets/liquid_glass.dart';

/// How thick a glass surface is. Thin: nav bar and pills. Regular: cards and
/// panels. Thick: sheets and dialogs.
enum GlassLevel { thin, regular, thick }

/// Shared values for every glass surface, so blur, tint and rim match.
class GlassTokens {
  GlassTokens._();

  /// Weak phones get a light blur with no colour boost.
  static final bool lowEnd = _detectLowEnd();

  static bool _detectLowEnd() {
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid && Platform.numberOfProcessors <= 4;
    } catch (_) {
      return false;
    }
  }

  static double sigma(GlassLevel level) {
    if (lowEnd) return 8;
    switch (level) {
      case GlassLevel.thin:
        return 10;
      case GlassLevel.regular:
        return 18;
      case GlassLevel.thick:
        return 28;
    }
  }

  /// Off when liquid glass is switched off or the system asks for contrast.
  static bool reduced(BuildContext context) {
    final mq = MediaQuery.maybeOf(context);
    return !LiquidGlassScope.of(context) || (mq?.highContrast ?? false);
  }

  /// Saturation matrix (luma-preserving) with a small brightness lift.
  static ColorFilter saturate(double s, {double lift = 0}) {
    const r = 0.2126, g = 0.7152, b = 0.0722;
    return ColorFilter.matrix(<double>[
      r * (1 - s) + s, g * (1 - s), b * (1 - s), 0, lift,
      r * (1 - s), g * (1 - s) + s, b * (1 - s), 0, lift,
      r * (1 - s), g * (1 - s), b * (1 - s) + s, 0, lift,
      0, 0, 0, 1, 0,
    ]);
  }

  /// Blur plus the iOS-style colour boost behind the glass.
  static ui.ImageFilter filter(double sigma, {required bool dark}) {
    final s = lowEnd ? math.min(sigma, 8.0) : sigma;
    final blur = ui.ImageFilter.blur(sigmaX: s, sigmaY: s, tileMode: TileMode.clamp);
    if (lowEnd) return blur;
    return ui.ImageFilter.compose(
      outer: saturate(dark ? 1.6 : 1.8, lift: dark ? 0 : 6),
      inner: blur,
    );
  }

  /// Plain blur for video and music overlays (no colour boost over video),
  /// lighter on weak phones.
  static ui.ImageFilter blur(double sigma) {
    final s = lowEnd ? math.min(sigma, 8.0) : sigma;
    return ui.ImageFilter.blur(sigmaX: s, sigmaY: s);
  }

  static List<Color> tint(bool dark, {GlassLevel level = GlassLevel.regular}) {
    final boost = level == GlassLevel.thick ? 0.18 : 0.0;
    return dark
        ? [
            const Color(0xFF1C1C1E).withValues(alpha: 0.52 + boost),
            const Color(0xFF1C1C1E).withValues(alpha: 0.40 + boost),
          ]
        : [
            Colors.white.withValues(alpha: 0.55 + boost),
            Colors.white.withValues(alpha: 0.40 + boost),
          ];
  }

  static Color solid(bool dark) =>
      dark ? const Color(0xEB1C1C1E) : const Color(0xEBFFFFFF);

  /// Tight contact shadow plus a soft ambient one.
  static List<BoxShadow> shadows(bool dark, {bool lifted = true}) => [
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.30 : 0.08),
          blurRadius: 2,
          offset: const Offset(0, 1),
        ),
        if (lifted)
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.40 : 0.10),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
      ];

  /// Smooth iOS-style corners.
  static ShapeBorder shape(double radius, {BorderSide side = BorderSide.none}) {
    if (radius >= 999) return StadiumBorder(side: side);
    return RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(radius),
      side: side,
    );
  }
}

/// Frosted surface tuned for light and dark: boosted blur, neutral tint,
/// bright top rim, specular sheen, grain and layered shadows. Falls back to a
/// solid fill when liquid glass is off or high contrast is on.
class PremiumGlass extends StatelessWidget {
  const PremiumGlass({
    super.key,
    required this.child,
    this.radius = 28,
    this.level = GlassLevel.regular,
    this.blur = true,
    this.padding,
    this.shadow = true,
    this.lifted = true,
    this.grouped = false,
  });

  final Widget child;
  final double radius;
  final GlassLevel level;

  /// False paints the same glass without sampling the screen (lists).
  final bool blur;
  final EdgeInsetsGeometry? padding;
  final bool shadow;
  final bool lifted;

  /// Shares one backdrop pass with siblings under a [BackdropGroup].
  final bool grouped;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final reduce = GlassTokens.reduced(context);
    final shape = GlassTokens.shape(radius);
    final colors = reduce
        ? [GlassTokens.solid(dark), GlassTokens.solid(dark)]
        : GlassTokens.tint(dark, level: level);

    Widget body = CustomPaint(
      foregroundPainter: GlassRimPainter(dark: dark, radius: radius, reduced: reduce),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: colors,
          ),
        ),
        child: padding == null ? child : Padding(padding: padding!, child: child),
      ),
    );
    if (blur && !reduce) {
      final filter = GlassTokens.filter(GlassTokens.sigma(level), dark: dark);
      body = grouped
          ? BackdropFilter.grouped(filter: filter, child: body)
          : BackdropFilter(filter: filter, child: body);
    }
    body = ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: body,
    );
    if (!shadow) return body;
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: GlassTokens.shadows(dark, lifted: lifted),
      ),
      child: body,
    );
  }
}

/// 1 px rim (bright top, faint bottom), a soft sheen on the top third and a
/// light grain so large panels do not band.
class GlassRimPainter extends CustomPainter {
  GlassRimPainter({required this.dark, required this.radius, this.reduced = false})
      : super(repaint: GlassGrain.image);

  final bool dark;
  final double radius;
  final bool reduced;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final r = math.min(radius, size.shortestSide / 2);
    final outer = RSuperellipse.fromRectAndRadius(rect, Radius.circular(r));
    final rim = RSuperellipse.fromRectAndRadius(rect.deflate(0.5), Radius.circular(math.max(0, r - 0.5)));
    if (reduced) {
      canvas.drawRSuperellipse(
        rim,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = (dark ? Colors.white : Colors.black).withValues(alpha: dark ? 0.16 : 0.18),
      );
      return;
    }
    canvas.save();
    canvas.clipRSuperellipse(outer);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height * (dark ? 0.14 : 0.38)),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: dark ? 0.045 : 0.26),
            const Color(0x00FFFFFF),
          ],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height * 0.38)),
    );
    final grain = GlassGrain.image.value;
    if (grain != null) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ImageShader(grain, TileMode.repeated, TileMode.repeated, Matrix4.identity().storage)
          ..blendMode = BlendMode.overlay
          ..color = Colors.white.withValues(alpha: dark ? 0.035 : 0.025),
      );
    }
    canvas.restore();
    canvas.drawRSuperellipse(
      rim,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: dark ? 0.16 : 0.85),
            Colors.white.withValues(alpha: dark ? 0.03 : 0.15),
            Colors.black.withValues(alpha: dark ? 0.30 : 0.06),
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant GlassRimPainter old) =>
      old.dark != dark || old.radius != radius || old.reduced != reduced;
}

/// A 96 px noise tile made once at start-up and shared by every glass panel.
class GlassGrain {
  GlassGrain._();

  static final ValueNotifier<ui.Image?> image = ValueNotifier<ui.Image?>(null);
  static bool _started = false;

  static void ensure() {
    if (_started) return;
    _started = true;
    const n = 96;
    final rnd = math.Random(7);
    final pixels = Uint8List(n * n * 4);
    for (var i = 0; i < n * n; i++) {
      final v = 96 + rnd.nextInt(64);
      pixels[i * 4] = v;
      pixels[i * 4 + 1] = v;
      pixels[i * 4 + 2] = v;
      pixels[i * 4 + 3] = 255;
    }
    ui.decodeImageFromPixels(pixels, n, n, ui.PixelFormat.rgba8888, (img) {
      image.value = img;
    });
  }
}
