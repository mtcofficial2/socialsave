import 'package:flutter/material.dart';
import 'package:social_save/core/theme/app_colors.dart';
import 'package:social_save/shared/models/social_platform.dart';

class PlatformBadge extends StatelessWidget {
  const PlatformBadge({
    super.key,
    required this.platform,
    this.compact = false,
    this.enabled = true,
  });

  final SocialPlatform platform;
  final bool compact;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = AppColors.platformColor(platform);
    final onColor = color.computeLuminance() > 0.45
        ? Colors.black
        : Colors.white;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: compact ? 10 : 12,
          backgroundColor: color,
          child: Text(
            platform.letter,
            style: TextStyle(
              color: onColor,
              fontSize: compact ? 8 : 9,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (!compact) ...[
          const SizedBox(width: 8),
          Text(
            platform.displayName,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: enabled
                      ? Theme.of(context).colorScheme.onSurface
                      : Theme.of(context).colorScheme.outline,
                ),
          ),
        ],
      ],
    );

    if (compact) {
      return Tooltip(message: platform.displayName, child: content);
    }
    return content;
  }
}
