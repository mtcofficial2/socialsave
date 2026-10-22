import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:social_save/shared/widgets/app_logo.dart';
import 'package:social_save/shared/widgets/liquid_glass.dart';

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
  const FloatingGlass({
    super.key,
    required this.radius,
    required this.child,
    this.bare = false,
    this.ghost = false,
  });

  final double radius;
  final bool bare;

  /// Nav-bar style: a light frost, a translucent fill, a hairline border and a
  /// soft shadow. The blur stays small so scrolling under the bar stays smooth.
  final bool ghost;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final shape = BorderRadius.circular(radius);
    if (ghost) {
      // One cheap blur. A second filter or a looping highlight inside this
      // bar forces the whole screen to re-blur and makes taps feel late.
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: shape,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.28 : 0.10),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: shape,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: (dark ? scheme.surfaceContainerHigh : scheme.surface)
                    .withValues(alpha: dark ? 0.32 : 0.40),
                borderRadius: shape,
                border: Border.all(
                  width: 0.8,
                  color: Colors.white.withValues(alpha: dark ? 0.22 : 0.70),
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
                color: (dark ? Colors.white : scheme.outline).withValues(
                  alpha: dark ? 0.14 : 0.25,
                ),
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
      dark
          ? Colors.white.withValues(alpha: 0.07)
          : scheme.onSurface.withValues(alpha: 0.03),
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
                return Stack(
                  children: [
                    // Liquid-glass lens behind the active tab's icon and label.
                    // Off: the same travel, with the flat oval fill.
                    LiquidSlider(
                      index: index.clamp(0, _tabs.length - 1).toInt(),
                      count: _tabs.length,
                      slotWidth: w,
                      dark: scheme.brightness == Brightness.dark,
                      glass: LiquidGlassScope.of(context),
                      flatColor: ovalColor(scheme),
                      navKey: true,
                    ),
                    Row(
                      children: [
                        for (var i = 0; i < _tabs.length; i++)
                          _item(
                            context,
                            i,
                            _tabs[i].$1,
                            _tabs[i].$2,
                            _tabs[i].$3,
                            badge: i == 2 ? downloadBadge : 0,
                          ),
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
    final color = selected
        ? scheme.primary
        : scheme.onSurface.withValues(alpha: 0.86);
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
                          child: Icon(
                            selected ? selectedIcon : icon,
                            key: ValueKey(selected),
                            color: color,
                            size: 24,
                          ),
                        ),
                        if (badge > 0)
                          Positioned(
                            top: -6,
                            right: -10,
                            child: Container(
                              constraints: const BoxConstraints(
                                minWidth: 18,
                                minHeight: 18,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: scheme.surface,
                                  width: 2,
                                ),
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
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(label, maxLines: 1, softWrap: false),
                    ),
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


