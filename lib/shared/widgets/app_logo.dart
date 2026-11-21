import 'package:flutter/material.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/platform/plat.dart';

class AppLogo extends StatelessWidget {
  const AppLogo({
    super.key,
    this.size = 40,
    this.showWordmark = false,
  });

  final double size;
  final bool showWordmark;

  @override
  Widget build(BuildContext context) {
    // Windows and Android use the ribbon alone, so the page or launcher
    // color shows through. Other targets keep the filled tile.
    final bare = Plat.isWindows || Plat.isAndroid;
    final image = Image.asset(
      bare ? 'assets/brand/icon_foreground_1024.png' : 'assets/brand/icon_1024.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
    final mark = bare
        ? image
        : ClipRRect(
            borderRadius: BorderRadius.circular(size * 0.28),
            child: image,
          );

    if (!showWordmark) {
      return mark;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        const SizedBox(width: 10),
        Text(
          AppConstants.appName,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
                fontSize: 18,
                color: Theme.of(context).colorScheme.primary,
                height: 1,
              ),
        ),
      ],
    );
  }
}
