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
              _SideDestination(
                selected: index == 0,
                icon: Icons.home_outlined,
                selectedIcon: Icons.home_rounded,
                label: 'Home',
                onTap: () => onSelect(0),
              ),
              _SideDestination(
                selected: index == 1,
                icon: Icons.video_library_outlined,
                selectedIcon: Icons.video_library_rounded,
                label: 'Library',
                onTap: () => onSelect(1),
              ),
              _SideDestination(
                selected: index == 2,
                icon: Icons.download_outlined,
                selectedIcon: Icons.download_rounded,
                label: 'Downloads',
                badge: downloadBadge,
                onTap: () => onSelect(2),
              ),
              _SideDestination(
                selected: index == 3,
                icon: Icons.tune_outlined,
                selectedIcon: Icons.tune_rounded,
                label: 'Settings',
                onTap: () => onSelect(3),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: MouseRegion(
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
            constraints: const BoxConstraints(minHeight: 46),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.20)
                  : _hover
                      ? scheme.onSurface.withValues(alpha: 0.06)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Icon(selected ? widget.selectedIcon : widget.icon, size: 22, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
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
            ),
          ),
        ),
        ),
      ),
    );
  }
}
