import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:social_save/core/platform/plat.dart';
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

  static String? assetFor(SocialPlatform platform, {bool bare = false}) {
    final mark = bare ? '_mark' : '';
    switch (platform) {
      case SocialPlatform.tiktok:
        return 'assets/platforms/tiktok$mark.svg';
      case SocialPlatform.instagram:
        return 'assets/platforms/instagram$mark.svg';
      case SocialPlatform.facebook:
        return 'assets/platforms/facebook$mark.svg';
      case SocialPlatform.x:
        return 'assets/platforms/x$mark.svg';
      case SocialPlatform.youtube:
        return 'assets/platforms/youtube$mark.svg';
      case SocialPlatform.reddit:
        return 'assets/platforms/reddit$mark.svg';
      case SocialPlatform.pinterest:
        return 'assets/platforms/pinterest$mark.svg';
      case SocialPlatform.direct:
        return 'assets/platforms/direct$mark.svg';
      case SocialPlatform.web:
      case SocialPlatform.unknown:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bare = Plat.isWindows;
    final asset = assetFor(platform, bare: bare);
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
      fit: bare ? BoxFit.contain : BoxFit.cover,
      theme: SvgTheme(currentColor: Theme.of(context).colorScheme.onSurface),
    );
  }
}
