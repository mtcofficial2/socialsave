import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/shared/widgets/app_logo.dart';
import 'package:social_save/shared/widgets/glass.dart';

class BrandHeader extends StatelessWidget {
  const BrandHeader({
    super.key,
    this.showBack = false,
    this.title,
    this.onBack,
  });

  final bool showBack;
  final String? title;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 12, 8),
      child: Row(
        children: [
          if (showBack)
            IconButton(
              onPressed: onBack ?? () => Navigator.maybePop(context),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
          if (title != null)
            Expanded(
              child: Text(
                title!,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.3,
                ),
              ),
            )
          else ...[
            const AppLogo(size: 32, showWordmark: true),
            const Spacer(),
          ],
          IconButton(
            tooltip: 'Settings',
            onPressed: () => context.go('/settings'),
            icon: Icon(Icons.tune_rounded, color: scheme.onSurfaceVariant),
          ),
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
              boxShadow: const [
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 4,
                  offset: Offset(0, 1),
                ),
              ],
            ),
            child: const Icon(Icons.person_rounded, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class StitchNavBar extends StatelessWidget {
  const StitchNavBar({
    super.key,
    required this.index,
    required this.onSelect,
    this.downloadBadge = 0,
  });

  final int index;
  final ValueChanged<int> onSelect;
  final int downloadBadge;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Glass(
        borderRadius: 32,
        blur: true,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 64,
            child: Row(
              children: [
                _item(context, 0, Icons.home_outlined, Icons.home_rounded, 'Home'),
                _item(
                  context,
                  1,
                  Icons.video_library_outlined,
                  Icons.video_library_rounded,
                  'Library',
                ),
                _item(
                  context,
                  2,
                  Icons.download_outlined,
                  Icons.download_rounded,
                  'Downloads',
                  badge: downloadBadge,
                ),
                _item(context, 3, Icons.tune_outlined, Icons.tune_rounded, 'Settings'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _item(
    BuildContext context,
    int i,
    IconData icon,
    IconData selectedIcon,
    String label, {
    int badge = 0,
  }) {
    final selected = index == i;
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Expanded(
      child: InkWell(
        onTap: () => onSelect(i),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              decoration: BoxDecoration(
                color: selected ? scheme.primary.withValues(alpha: 0.16) : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
                border: selected
                    ? Border.all(color: Colors.white.withValues(alpha: 0.45))
                    : null,
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(selected ? selectedIcon : icon, color: color, size: 24),
                  if (badge > 0)
                    Positioned(
                      top: -6,
                      right: -8,
                      child: Container(
                        width: 16,
                        height: 16,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          shape: BoxShape.circle,
                          border: Border.all(color: scheme.surface, width: 2),
                        ),
                        child: Text(
                          '$badge',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            height: 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
