import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:social_save/shared/widgets/app_logo.dart';

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
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
      child: Row(
        children: [
          if (showBack)
            IconButton(
              tooltip: 'Back',
              onPressed: onBack ?? () => Navigator.maybePop(context),
              icon: const Icon(Icons.arrow_back_rounded),
            ),
          if (title != null)
            Expanded(
              child: Text(
                title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
              ),
            )
          else
            const AppLogo(size: 32, showWordmark: true),
        ],
      ),
    );
  }
}

/// Frosted, detached surface: blur, low-opacity fill, hairline border and a
/// soft shadow, so what is behind it shows through.
class FloatingGlass extends StatelessWidget {
  const FloatingGlass({super.key, required this.radius, required this.child, this.bare = false, this.ghost = false});

  final double radius;
  final bool bare;

  /// Nav-bar style: almost no fill, true backdrop blur + a little saturation,
  /// no border, only a very soft ambient shadow.
  final bool ghost;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final shape = BorderRadius.circular(radius);
    if (ghost) {
      const s = 1.5;
      const r = 0.2126, g = 0.7152, bl = 0.0722;
      final matrix = <double>[
        r + (1 - r) * s, g - g * s, bl - bl * s, 0, 0,
        r - r * s, g + (1 - g) * s, bl - bl * s, 0, 0,
        r - r * s, g - g * s, bl + (1 - bl) * s, 0, 0,
        0, 0, 0, 1, 0,
      ];
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: shape,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.16 : 0.07),
              blurRadius: 30,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: shape,
          child: BackdropFilter(
            filter: ImageFilter.compose(
              outer: ColorFilter.matrix(matrix),
              inner: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            ),
            child: ColoredBox(
              color: scheme.surface.withValues(alpha: dark ? 0.10 : 0.12),
              child: Material(type: MaterialType.transparency, child: child),
            ),
          ),
        ),
      );
    }
    if (bare) {
      // Lighter variant: no border, no shadow, softer fill.
      return ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: dark ? 0.38 : 0.45),
              borderRadius: shape,
            ),
            child: Material(type: MaterialType.transparency, child: child),
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.45 : 0.16),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: dark ? 0.55 : 0.62),
              borderRadius: shape,
              border: Border.all(
                color: (dark ? Colors.white : scheme.outline).withValues(alpha: dark ? 0.14 : 0.25),
              ),
            ),
            child: Material(type: MaterialType.transparency, child: child),
          ),
        ),
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
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: FloatingGlass(
        radius: 32,
        ghost: true,
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
    final color = selected ? scheme.primary : scheme.onSurface.withValues(alpha: 0.82);
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkWell(
          onTap: () => onSelect(i),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 5),
                decoration: BoxDecoration(
                  color: selected ? scheme.primary.withValues(alpha: 0.20) : Colors.transparent,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: AnimatedScale(
                  scale: selected ? 1.1 : 1.0,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutBack,
                  child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(selected ? selectedIcon : icon, color: color, size: 24),
                    if (badge > 0)
                      Positioned(
                        top: -6,
                        right: -10,
                        child: Container(
                          constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: scheme.surface, width: 2),
                          ),
                          child: Text(
                            badge > 9 ? '9+' : '$badge',
                            style: TextStyle(
                              color: scheme.onPrimary,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              height: 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: color,
                  height: 1.1,
                  shadows: [Shadow(color: scheme.surface.withValues(alpha: 0.7), blurRadius: 6)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
