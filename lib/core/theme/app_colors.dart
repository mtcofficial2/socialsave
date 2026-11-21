import 'package:flutter/material.dart';
import 'package:social_save/shared/models/social_platform.dart';

class AppColors {
  const AppColors._();

  static const Color seed = Color(0xFF1B4FD8);
  static const Color seedDark = Color(0xFF8ECAFF);
  static const Color highlight = Color(0xFF38BDF8);

  static const Color primary = Color(0xFF1B4FD8);
  static const Color primaryContainer = Color(0xFF1D4ED8);
  static const Color onPrimaryContainer = Color(0xFFE8F1FF);
  static const Color secondary = Color(0xFF0369A1);
  static const Color secondaryContainer = Color(0xFF38BDF8);
  static const Color onSecondaryContainer = Color(0xFF0C4A6E);
  static const Color surface = Color(0xFFF6F8FC);
  static const Color surfaceLow = Color(0xFFF0F4FB);
  static const Color surfaceContainer = Color(0xFFE7EEF8);
  static const Color surfaceHigh = Color(0xFFDCE6F4);
  static const Color surfaceHighest = Color(0xFFD2DDED);
  static const Color card = Color(0xFFFFFFFF);
  static const Color ink = Color(0xFF131B2E);
  static const Color muted = Color(0xFF4A5568);
  static const Color outline = Color(0xFF5C6B82);
  static const Color outlineSoft = Color(0xFFE3E8F2);
  static const Color ok = Color(0xFF15803D);
  static const Color okSoft = Color(0xFFF0FDF4);
  static const Color error = Color(0xFFBA1A1A);
  static const Color danger = error;
  static const Color errorContainer = Color(0xFFFFDAD6);
  static const Color onErrorContainer = Color(0xFF93000A);
  static const Color inkLight = ink;
  static const Color okSoftLight = okSoft;
  static const Color okSoftDark = Color(0xFF163226);
  static const Color extractSoftLight = Color(0xFFDBEAFE);
  static const Color extractSoftDark = Color(0xFF1E3A5F);
  static const Color dangerSoftLight = errorContainer;
  static const Color dangerSoftDark = Color(0xFF3F1D1D);

  static const Color canvasDark = Color(0xFF070B14);
  static const Color cardDark = Color(0xFF101828);
  static const Color inkDark = Color(0xFFE8EEF8);
  static const Color mutedDark = Color(0xFFB4C0D4);

  /// Green that stays readable on the current canvas.
  static Color successFg(Brightness brightness) =>
      brightness == Brightness.dark ? const Color(0xFF4ADE80) : ok;

  static Color successBg(Brightness brightness) =>
      brightness == Brightness.dark ? okSoftDark : okSoft;

  /// Platform colors such as black disappear on a dark surface.
  static Color readableBrand(Color brand, ColorScheme scheme) {
    final gap = (brand.computeLuminance() - scheme.surface.computeLuminance()).abs();
    if (gap < 0.28) return scheme.onSurface;
    return brand;
  }

  static ColorScheme lightScheme() {
    return const ColorScheme(
      brightness: Brightness.light,
      primary: primary,
      onPrimary: Colors.white,
      primaryContainer: primaryContainer,
      onPrimaryContainer: onPrimaryContainer,
      secondary: secondary,
      onSecondary: Colors.white,
      secondaryContainer: secondaryContainer,
      onSecondaryContainer: onSecondaryContainer,
      tertiary: Color(0xFF4338CA),
      onTertiary: Colors.white,
      error: error,
      onError: Colors.white,
      errorContainer: errorContainer,
      onErrorContainer: onErrorContainer,
      surface: surface,
      onSurface: ink,
      onSurfaceVariant: muted,
      outline: outlineSoft,
      outlineVariant: Color(0xFFD0D7E6),
      inverseSurface: Color(0xFF1B2438),
      onInverseSurface: Color(0xFFF4F7FC),
      inversePrimary: seedDark,
      surfaceContainerLowest: card,
      surfaceContainerLow: surfaceLow,
      surfaceContainer: surfaceContainer,
      surfaceContainerHigh: surfaceHigh,
      surfaceContainerHighest: surfaceHighest,
    );
  }

  static ColorScheme darkScheme() {
    return const ColorScheme(
      brightness: Brightness.dark,
      primary: seedDark,
      onPrimary: Color(0xFF04244A),
      primaryContainer: primaryContainer,
      onPrimaryContainer: onPrimaryContainer,
      secondary: Color(0xFF67E8F9),
      onSecondary: Color(0xFF003844),
      secondaryContainer: Color(0xFF0C4A6E),
      onSecondaryContainer: Color(0xFFBAE6FD),
      tertiary: Color(0xFFA5B4FC),
      onTertiary: Color(0xFF1E1B4B),
      error: Color(0xFFFFB4AB),
      onError: Color(0xFF690005),
      errorContainer: Color(0xFF93000A),
      onErrorContainer: errorContainer,
      surface: canvasDark,
      onSurface: inkDark,
      onSurfaceVariant: mutedDark,
      outline: Color(0xFF243044),
      outlineVariant: Color(0xFF334155),
      inverseSurface: inkDark,
      onInverseSurface: ink,
      inversePrimary: primary,
      surfaceContainerLowest: cardDark,
      surfaceContainerLow: Color(0xFF101828),
      surfaceContainer: Color(0xFF172033),
      surfaceContainerHigh: Color(0xFF1E2A40),
      surfaceContainerHighest: Color(0xFF26344C),
    );
  }

  static Color platformColor(SocialPlatform platform) {
    switch (platform) {
      case SocialPlatform.tiktok:
        return const Color(0xFF000000);
      case SocialPlatform.instagram:
        return const Color(0xFFE1306C);
      case SocialPlatform.facebook:
        return const Color(0xFF1877F2);
      case SocialPlatform.x:
        return const Color(0xFF0F1419);
      case SocialPlatform.youtube:
        return const Color(0xFFFF0000);
      case SocialPlatform.reddit:
        return const Color(0xFFFF4500);
      case SocialPlatform.pinterest:
        return const Color(0xFFE60023);
      case SocialPlatform.direct:
        return primary;
      case SocialPlatform.web:
        return seed;
      case SocialPlatform.unknown:
        return const Color(0xFF64748B);
    }
  }
}
