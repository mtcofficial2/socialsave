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

  /// Nav-bar style (1.0.45): a frosted floating pill. Backdrop blur with a
  /// little saturation, a translucent fill, a hairline border and a soft drop
  /// shadow, so it reads as floating in light and dark while content still
  /// shows through.
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
              color: Colors.black.withValues(alpha: dark ? 0.42 : 0.12),
              blurRadius: 28,
              offset: const Offset(0, 10),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.20 : 0.05),
              blurRadius: 4,
              offset: const Offset(0, 1),
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
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: (dark ? scheme.surfaceContainerHigh : scheme.surface).withValues(alpha: dark ? 0.50 : 0.58),
                borderRadius: shape,
                border: Border.all(
                  width: 0.8,
                  color: dark ? Colors.white.withValues(alpha: 0.12) : scheme.onSurface.withValues(alpha: 0.10),
                ),
              ),
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

  /// 1.0.47: fill of the active-tab oval (Telegram style): a soft, slightly
  /// lighter translucent stadium, tinted with the accent.
  static Color ovalColor(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    return Color.alphaBlend(
      scheme.primary.withValues(alpha: dark ? 0.16 : 0.13),
      dark ? Colors.white.withValues(alpha: 0.07) : scheme.onSurface.withValues(alpha: 0.03),
    );
  }

  static const _tabs = <(IconData, IconData, String)>[
    (Icons.home_outlined, Icons.home_rounded, 'Home'),
    (Icons.video_library_outlined, Icons.video_library_rounded, 'Library'),
    (Icons.download_outlined, Icons.download_rounded, 'Downloads'),
    (Icons.tune_outlined, Icons.tune_rounded, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    // 1.0.45: a detached pill, 16 px in from the sides and a little above the
    // system inset, instead of reaching down into the gesture area.
    final inset = MediaQuery.paddingOf(context).bottom;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 10 + inset),
      child: FloatingGlass(
        radius: 999,
        ghost: true,
        child: MediaQuery.removePadding(
          context: context,
          removeBottom: true,
          child: SizedBox(
            height: 64,
            child: LayoutBuilder(
              builder: (context, box) {
                final w = box.maxWidth / _tabs.length;
                const pad = 5.0;
                return Stack(
                  children: [
                    // One oval behind the active tab's icon AND label; it
                    // slides to the tapped tab.
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOutCubic,
                      left: w * index.clamp(0, _tabs.length - 1) + pad,
                      top: pad,
                      bottom: pad,
                      width: w - pad * 2,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          key: const ValueKey('nav-active-oval'),
                          decoration: ShapeDecoration(
                            color: ovalColor(scheme),
                            shape: const StadiumBorder(),
                          ),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        for (var i = 0; i < _tabs.length; i++)
                          _item(context, i, _tabs[i].$1, _tabs[i].$2, _tabs[i].$3, badge: i == 2 ? downloadBadge : 0),
                      ],
                    ),
                  ],
                );
              },
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
    final color = selected ? scheme.primary : scheme.onSurface.withValues(alpha: 0.86);
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Material(
            type: MaterialType.transparency,
            shape: const StadiumBorder(),
            child: InkWell(
              onTap: () => onSelect(i),
              customBorder: const StadiumBorder(),
              // Stadium-shaped feedback only: no square highlight flash.
              highlightColor: Colors.transparent,
              hoverColor: scheme.onSurface.withValues(alpha: 0.04),
              splashColor: scheme.primary.withValues(alpha: 0.10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedScale(
                    scale: selected ? 1.06 : 1.0,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutBack,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          child: Icon(selected ? selectedIcon : icon, key: ValueKey(selected), color: color, size: 24),
                        ),
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
                  const SizedBox(height: 3),
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 220),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      color: color,
                      height: 1.1,
                    ),
                    child: FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1, softWrap: false)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
