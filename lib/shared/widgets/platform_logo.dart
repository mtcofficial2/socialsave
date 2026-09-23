import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:social_save/core/theme/app_colors.dart';
import 'package:social_save/shared/models/social_platform.dart';

class PlatformLogo extends StatelessWidget {
  const PlatformLogo({
    super.key,
    required this.platform,
    this.size = 20,
  });

  final SocialPlatform platform;
  final double size;

  static String? assetFor(SocialPlatform platform) {
    switch (platform) {
      case SocialPlatform.tiktok:
        return 'assets/platforms/tiktok.svg';
      case SocialPlatform.instagram:
        return 'assets/platforms/instagram.svg';
      case SocialPlatform.facebook:
        return 'assets/platforms/facebook.svg';
      case SocialPlatform.x:
        return 'assets/platforms/x.svg';
      case SocialPlatform.youtube:
        return 'assets/platforms/youtube.svg';
      case SocialPlatform.reddit:
        return 'assets/platforms/reddit.svg';
      case SocialPlatform.pinterest:
        return 'assets/platforms/pinterest.svg';
      case SocialPlatform.direct:
        return 'assets/platforms/direct.svg';
      case SocialPlatform.unknown:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final asset = assetFor(platform);
    if (asset == null) {
      return Icon(
        Icons.link_rounded,
        size: size,
        color: AppColors.platformColor(platform),
      );
    }
    return SvgPicture.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.cover,
    );
  }
}
