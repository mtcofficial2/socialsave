import 'package:flutter/material.dart';
import 'package:social_save/core/theme/app_colors.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/widgets/platform_logo.dart';

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
    final scheme = Theme.of(context).colorScheme;
    final color = AppColors.platformColor(platform);
    return Container(
      height: compact ? 26 : 32,
      padding: EdgeInsets.fromLTRB(compact ? 8 : 8, 0, compact ? 10 : 12, 0),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Opacity(
            opacity: enabled ? 1 : 0.45,
            child: PlatformLogo(platform: platform, size: compact ? 16 : 18),
          ),
          const SizedBox(width: 6),
          Text(
            platform.displayName,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontSize: compact ? 11 : 12,
                  fontWeight: FontWeight.w600,
                  color: enabled ? color : scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.label,
    this.kind = StatusBadgeKind.public,
  });

  final String label;
  final StatusBadgeKind kind;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final Color bg;
    final Color fg;
    switch (kind) {
      case StatusBadgeKind.public:
        bg = dark ? AppColors.okSoftDark : AppColors.okSoftLight;
        fg = dark ? const Color(0xFF4ADE80) : AppColors.ok;
      case StatusBadgeKind.extracting:
        bg = dark ? AppColors.extractSoftDark : AppColors.extractSoftLight;
        fg = dark ? AppColors.seedDark : AppColors.seed;
      case StatusBadgeKind.restricted:
        bg = dark ? AppColors.dangerSoftDark : AppColors.dangerSoftLight;
        fg = dark ? const Color(0xFFF87171) : AppColors.danger;
    }
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

enum StatusBadgeKind { public, extracting, restricted }
