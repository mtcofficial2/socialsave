import 'package:flutter/material.dart';
import 'package:social_save/shared/models/social_platform.dart';
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
    (SocialPlatform.web, 'Other websites'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Supported Platforms',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 34,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _chips.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final item = _chips[index];
              return DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(99),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PlatformLogo(platform: item.$1, size: 14),
                      const SizedBox(width: 6),
                      Text(
                        item.$2,
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
