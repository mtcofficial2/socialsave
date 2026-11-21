import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Design tokens: the one place for spacing, corner radii, motion and named
/// text styles. Read them with `context.tokens` (theme-aware text styles) or,
/// inside `const` widgets, with [AppSpacing], [AppRadii] and [AppDurations].
///
/// Keep new UI on these values instead of one-off numbers so every screen
/// lines up on the same grid and moves at the same speed.
abstract final class AppSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// Horizontal page gutter on phones.
  static const double gutter = lg;
}

abstract final class AppRadii {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double pill = 999;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(pill));
}

abstract final class AppDurations {
  /// Hover, press and small state flips.
  static const Duration fast = Duration(milliseconds: 120);

  /// Default for most transitions (icons, colors, sizes).
  static const Duration normal = Duration(milliseconds: 200);

  /// Larger movements: sheets, page content, emphasis.
  static const Duration slow = Duration(milliseconds: 350);

  static const Curve curve = Curves.easeOutCubic;
}

@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.spaceXs,
    required this.spaceSm,
    required this.spaceMd,
    required this.spaceLg,
    required this.spaceXl,
    required this.spaceXxl,
    required this.radiusSm,
    required this.radiusMd,
    required this.radiusLg,
    required this.radiusXl,
    required this.radiusPill,
    required this.fast,
    required this.normal,
    required this.slow,
    required this.pageTitle,
    required this.sectionTitle,
    required this.itemTitle,
    required this.itemSubtitle,
    required this.body,
    required this.caption,
    required this.label,
    required this.badge,
  });

  /// Builds the tokens from a finished text theme and color scheme.
  factory AppTokens.from(TextTheme text, ColorScheme scheme) {
    TextStyle base(TextStyle? s) => s ?? const TextStyle();
    return AppTokens(
      spaceXs: AppSpacing.xs,
      spaceSm: AppSpacing.sm,
      spaceMd: AppSpacing.md,
      spaceLg: AppSpacing.lg,
      spaceXl: AppSpacing.xl,
      spaceXxl: AppSpacing.xxl,
      radiusSm: AppRadii.sm,
      radiusMd: AppRadii.md,
      radiusLg: AppRadii.lg,
      radiusXl: AppRadii.xl,
      radiusPill: AppRadii.pill,
      fast: AppDurations.fast,
      normal: AppDurations.normal,
      slow: AppDurations.slow,
      pageTitle: base(text.headlineSmall).copyWith(
        fontWeight: FontWeight.w800,
        letterSpacing: -0.5,
        color: scheme.onSurface,
      ),
      sectionTitle: base(text.titleMedium).copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
      ),
      itemTitle: base(text.bodyLarge).copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      itemSubtitle: base(text.bodyMedium).copyWith(
        fontSize: 13,
        height: 1.3,
        color: scheme.onSurfaceVariant,
      ),
      body: base(text.bodyMedium).copyWith(color: scheme.onSurface),
      caption: base(text.bodySmall).copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: scheme.onSurfaceVariant,
      ),
      label: base(text.labelLarge).copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      badge: base(text.labelSmall).copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        height: 1,
        letterSpacing: 0,
        color: scheme.onPrimary,
      ),
    );
  }

  final double spaceXs;
  final double spaceSm;
  final double spaceMd;
  final double spaceLg;
  final double spaceXl;
  final double spaceXxl;

  final double radiusSm;
  final double radiusMd;
  final double radiusLg;
  final double radiusXl;
  final double radiusPill;

  final Duration fast;
  final Duration normal;
  final Duration slow;

  /// Large page heading.
  final TextStyle pageTitle;

  /// Heading of a group of rows (Settings sections, list headers).
  final TextStyle sectionTitle;

  /// Primary line of a row or card.
  final TextStyle itemTitle;

  /// Secondary line of a row or card.
  final TextStyle itemSubtitle;

  final TextStyle body;

  /// Small muted meta text (versions, counts, timestamps).
  final TextStyle caption;

  /// Button-like labels (nav destinations, chips).
  final TextStyle label;

  /// Counter inside a small badge.
  final TextStyle badge;

  @override
  AppTokens copyWith({
    TextStyle? pageTitle,
    TextStyle? sectionTitle,
    TextStyle? itemTitle,
    TextStyle? itemSubtitle,
    TextStyle? body,
    TextStyle? caption,
    TextStyle? label,
    TextStyle? badge,
  }) {
    return AppTokens(
      spaceXs: spaceXs,
      spaceSm: spaceSm,
      spaceMd: spaceMd,
      spaceLg: spaceLg,
      spaceXl: spaceXl,
      spaceXxl: spaceXxl,
      radiusSm: radiusSm,
      radiusMd: radiusMd,
      radiusLg: radiusLg,
      radiusXl: radiusXl,
      radiusPill: radiusPill,
      fast: fast,
      normal: normal,
      slow: slow,
      pageTitle: pageTitle ?? this.pageTitle,
      sectionTitle: sectionTitle ?? this.sectionTitle,
      itemTitle: itemTitle ?? this.itemTitle,
      itemSubtitle: itemSubtitle ?? this.itemSubtitle,
      body: body ?? this.body,
      caption: caption ?? this.caption,
      label: label ?? this.label,
      badge: badge ?? this.badge,
    );
  }

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) return this;
    double d(double a, double b) => lerpDouble(a, b, t)!;
    TextStyle s(TextStyle a, TextStyle b) => TextStyle.lerp(a, b, t)!;
    return AppTokens(
      spaceXs: d(spaceXs, other.spaceXs),
      spaceSm: d(spaceSm, other.spaceSm),
      spaceMd: d(spaceMd, other.spaceMd),
      spaceLg: d(spaceLg, other.spaceLg),
      spaceXl: d(spaceXl, other.spaceXl),
      spaceXxl: d(spaceXxl, other.spaceXxl),
      radiusSm: d(radiusSm, other.radiusSm),
      radiusMd: d(radiusMd, other.radiusMd),
      radiusLg: d(radiusLg, other.radiusLg),
      radiusXl: d(radiusXl, other.radiusXl),
      radiusPill: d(radiusPill, other.radiusPill),
      fast: t < 0.5 ? fast : other.fast,
      normal: t < 0.5 ? normal : other.normal,
      slow: t < 0.5 ? slow : other.slow,
      pageTitle: s(pageTitle, other.pageTitle),
      sectionTitle: s(sectionTitle, other.sectionTitle),
      itemTitle: s(itemTitle, other.itemTitle),
      itemSubtitle: s(itemSubtitle, other.itemSubtitle),
      body: s(body, other.body),
      caption: s(caption, other.caption),
      label: s(label, other.label),
      badge: s(badge, other.badge),
    );
  }
}

extension AppTokensContext on BuildContext {
  /// Design tokens of the current theme. Falls back to tokens built from the
  /// current theme when a widget is shown outside [AppTheme] (tests, previews).
  AppTokens get tokens {
    final theme = Theme.of(this);
    return theme.extension<AppTokens>() ?? AppTokens.from(theme.textTheme, theme.colorScheme);
  }
}
