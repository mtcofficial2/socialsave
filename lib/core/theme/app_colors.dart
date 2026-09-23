import 'package:flutter/material.dart';
import 'package:social_save/shared/models/social_platform.dart';

class AppColors {
  const AppColors._();

  static const Color seed = Color(0xFF0F766E);
  static const Color seedDark = Color(0xFF80D5CB);
  static const Color highlight = Color(0xFF14B8A6);

  static const Color primary = Color(0xFF005C55);
  static const Color primaryContainer = Color(0xFF0F766E);
  static const Color onPrimaryContainer = Color(0xFFA3FAEF);
  static const Color secondary = Color(0xFF006B5F);
  static const Color secondaryContainer = Color(0xFF62FAE3);
  static const Color onSecondaryContainer = Color(0xFF007165);
  static const Color surface = Color(0xFFFAF8FF);
  static const Color surfaceLow = Color(0xFFF2F3FF);
  static const Color surfaceContainer = Color(0xFFEAEDFF);
  static const Color surfaceHigh = Color(0xFFE2E7FF);
  static const Color surfaceHighest = Color(0xFFDAE2FD);
  static const Color card = Color(0xFFFFFFFF);
  static const Color ink = Color(0xFF131B2E);
  static const Color muted = Color(0xFF3E4947);
  static const Color outline = Color(0xFF6E7977);
  static const Color outlineSoft = Color(0xFFE2E8F0);
  static const Color ok = Color(0xFF15803D);
  static const Color okSoft = Color(0xFFF0FDF4);
  static const Color error = Color(0xFFBA1A1A);
  static const Color danger = error;
  static const Color errorContainer = Color(0xFFFFDAD6);
  static const Color onErrorContainer = Color(0xFF93000A);
  static const Color inkLight = ink;
  static const Color okSoftLight = okSoft;
  static const Color okSoftDark = Color(0xFF163226);
  static const Color extractSoftLight = Color(0xFFCCFBF1);
  static const Color extractSoftDark = Color(0xFF134E4A);
  static const Color dangerSoftLight = errorContainer;
  static const Color dangerSoftDark = Color(0xFF3F1D1D);

  static const Color canvasDark = Color(0xFF0B1219);
  static const Color cardDark = Color(0xFF141C28);
  static const Color inkDark = Color(0xFFE8EEF6);
  static const Color mutedDark = Color(0xFF93A0B5);

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
      tertiary: Color(0xFF005C52),
      onTertiary: Colors.white,
      error: error,
      onError: Colors.white,
      errorContainer: errorContainer,
      onErrorContainer: onErrorContainer,
      surface: surface,
      onSurface: ink,
      onSurfaceVariant: muted,
      outline: outlineSoft,
      outlineVariant: Color(0xFFBDC9C6),
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
      onPrimary: Color(0xFF00201D),
      primaryContainer: primaryContainer,
      onPrimaryContainer: onPrimaryContainer,
      secondary: Color(0xFF3CDDC7),
      onSecondary: Color(0xFF00201C),
      secondaryContainer: Color(0xFF005047),
      onSecondaryContainer: secondaryContainer,
      tertiary: Color(0xFF4FDBC8),
      onTertiary: Color(0xFF00201C),
      error: Color(0xFFFFB4AB),
      onError: Color(0xFF690005),
      errorContainer: Color(0xFF93000A),
      onErrorContainer: errorContainer,
      surface: canvasDark,
      onSurface: inkDark,
      onSurfaceVariant: mutedDark,
      outline: Color(0xFF243044),
      outlineVariant: Color(0xFF3A4658),
      surfaceContainerLowest: cardDark,
      surfaceContainerLow: Color(0xFF121A26),
      surfaceContainer: Color(0xFF1B2433),
      surfaceContainerHigh: Color(0xFF243044),
      surfaceContainerHighest: Color(0xFF2C3A50),
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
        return const Color(0xFF0F766E);
      case SocialPlatform.unknown:
        return const Color(0xFF64748B);
    }
  }
}
