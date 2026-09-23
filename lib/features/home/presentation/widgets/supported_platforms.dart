import 'package:flutter/material.dart';
import 'package:social_save/core/theme/app_colors.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/widgets/glass.dart';
import 'package:social_save/shared/widgets/platform_logo.dart';

class SupportedPlatformsSection extends StatelessWidget {
  const SupportedPlatformsSection({super.key});

  static const _chips = <(SocialPlatform, String)>[
    (SocialPlatform.tiktok, 'TikTok'),
    (SocialPlatform.instagram, 'Instagram'),
    (SocialPlatform.youtube, 'YouTube'),
    (SocialPlatform.x, 'X (Twitter)'),
    (SocialPlatform.facebook, 'Facebook'),
    (SocialPlatform.reddit, 'Reddit'),
    (SocialPlatform.pinterest, 'Pinterest'),
    (SocialPlatform.direct, 'Direct MP4/WebM'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Supported Platforms',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
            ),
            const Spacer(),
            Text(
              '8 Public Engines',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _chips.map((item) {
            final color = AppColors.platformColor(item.$1);
            return Glass(
              borderRadius: 999,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PlatformLogo(platform: item.$1, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    item.$2,
                    style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
