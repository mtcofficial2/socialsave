import 'package:social_save/shared/widgets/brand_header.dart';
import 'package:social_save/shared/widgets/liquid_glass.dart';
import 'package:flutter/material.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/shared/widgets/app_logo.dart';
import 'package:social_save/shared/widgets/page_layout.dart';

class DesktopSidebar extends StatelessWidget {
  const DesktopSidebar({
    super.key,
    required this.index,
    required this.onSelect,
    this.downloadBadge = 0,
    this.onShare,
    this.onMusic,
  });

  final VoidCallback? onMusic;

  final VoidCallback? onShare;
  final int index;
  final ValueChanged<int> onSelect;
  final int downloadBadge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: kDesktopSidebarWidth,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.30),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 22, 14, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(8, 0, 8, 22),
                child: AppLogo(size: 32, showWordmark: true),
              ),
              _SideNav(
                index: index,
                downloadBadge: downloadBadge,
                onSelect: onSelect,
              ),
              if (onMusic != null) ...[
                const SizedBox(height: 10),
                TextButton.icon(
                  key: const ValueKey('sidebar-music'),
                  onPressed: onMusic,
                  icon: const Icon(Icons.library_music_rounded),
                  label: const Text('Music'),
                ),
              ],
              if (onShare != null) ...[
                const SizedBox(height: 10),
                FilledButton.tonalIcon(
                  key: const ValueKey('sidebar-share'),
                  onPressed: onShare,
                  icon: const Icon(Icons.swap_horiz_rounded),
                  label: const Text('Send / Receive'),
                ),
              ],
              const Spacer(),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 8, 0),
                child: Text(
                  'SocialSave ${AppConstants.appVersion}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One slot per destination. The lens travels inside this stack, the same
/// stretch the phone tab bar uses, along the column instead of the row.
const double _kSideSlot = 48;

class _SideNav extends StatelessWidget {
  const _SideNav({
    required this.index,
    required this.downloadBadge,
    required this.onSelect,
  });

  final int index;
  final int downloadBadge;
  final ValueChanged<int> onSelect;

  static const _tabs = <(IconData, IconData, String)>[
    (Icons.home_outlined, Icons.home_rounded, 'Home'),
    (Icons.video_library_outlined, Icons.video_library_rounded, 'Library'),
    (Icons.download_outlined, Icons.download_rounded, 'Downloads'),
    (Icons.tune_outlined, Icons.tune_rounded, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = index.clamp(0, _tabs.length - 1).toInt();
    return SizedBox(
      height: _kSideSlot * _tabs.length,
      child: Stack(
        children: [
          LiquidSlider(
            index: selected,
            count: _tabs.length,
            slotWidth: _kSideSlot,
            vertical: true,
            dark: scheme.brightness == Brightness.dark,
            glass: LiquidGlassScope.of(context),
            flatColor: StitchNavBar.ovalColor(scheme),
            navKey: true,
            pad: 4,
          ),
          Column(
            children: [
              for (var i = 0; i < _tabs.length; i++)
                SizedBox(
                  height: _kSideSlot,
                  child: _SideDestination(
                    selected: selected == i,
                    icon: _tabs[i].$1,
                    selectedIcon: _tabs[i].$2,
                    label: _tabs[i].$3,
                    badge: i == 2 ? downloadBadge : 0,
                    onTap: () => onSelect(i),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SideDestination extends StatefulWidget {
  const _SideDestination({
    required this.selected,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.onTap,
    this.badge = 0,
  });

  final bool selected;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final VoidCallback onTap;
  final int badge;

  @override
  State<_SideDestination> createState() => _SideDestinationState();
}

class _SideDestinationState extends State<_SideDestination> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = widget.selected;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    final row = Row(
      children: [
        Icon(selected ? widget.selectedIcon : widget.icon, size: 22, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
        if (widget.badge > 0)
          Container(
            constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              widget.badge > 9 ? '9+' : '${widget.badge}',
              style: TextStyle(
                color: scheme.onPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Semantics(
        button: true,
        selected: selected,
        label: widget.badge > 0 ? '${widget.label}, ${widget.badge} new' : widget.label,
        excludeSemantics: true,
        onTap: widget.onTap,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: !selected && _hover
                  ? scheme.onSurface.withValues(alpha: 0.06)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: row,
          ),
        ),
      ),
    );
  }
}
