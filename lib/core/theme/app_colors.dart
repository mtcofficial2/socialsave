import 'package:flutter/material.dart';
import 'package:social_save/shared/models/social_platform.dart';

class AppColors {
  const AppColors._();

  static const Color seed = Color(0xFF0F766E);
  static const Color seedDark = Color(0xFF2DD4BF);
  static const Color highlight = Color(0xFF14B8A6);

  static Color platformColor(SocialPlatform platform) {
    switch (platform) {
      case SocialPlatform.tiktok:
        return const Color(0xFF111111);
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
        return seed;
      case SocialPlatform.unknown:
        return const Color(0xFF64748B);
    }
  }
}
