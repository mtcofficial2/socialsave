import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/theme/app_tokens.dart';
import 'package:social_save/features/chat/chat_history.dart';
import 'package:social_save/shared/widgets/page_layout.dart';

/// The More tab: everything that is not about saving videos lives here, so
/// the main tabs stay focused on Home, Library, Downloads and Settings.
///
/// Each entry opens its existing page (`/chat`, `/music`, `/share`), so deep
/// links and other buttons that push those routes keep working.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  static const _entries = <_MoreEntry>[
    _MoreEntry(
      key: ValueKey('more-chat'),
      icon: Icons.forum_rounded,
      title: 'Chats',
      subtitle: 'Message people and groups, and post a status.',
      route: '/chat',
      showsUnread: true,
    ),
    _MoreEntry(
      key: ValueKey('more-music'),
      icon: Icons.library_music_rounded,
      title: 'Music',
      subtitle: 'Play songs and audio you saved, even with the screen off.',
      route: '/music',
    ),
    _MoreEntry(
      key: ValueKey('more-share'),
      icon: Icons.swap_horiz_rounded,
      title: 'Send / Receive',
      subtitle: 'Share videos and files with a nearby phone or computer.',
      route: '/share',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: pagePadding(
            context,
            top: AppSpacing.md,
            bottom: AppSpacing.xxl + 96 + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            Semantics(
              header: true,
              child: Text('More', style: pageTitleStyle(context)),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text('Chats, music, and sharing with nearby devices.', style: tokens.itemSubtitle),
            const SizedBox(height: AppSpacing.xl),
            for (final entry in _entries) ...[
              _MoreTile(entry: entry),
              const SizedBox(height: AppSpacing.md),
            ],
          ],
        ),
      ),
    );
  }
}

@immutable
class _MoreEntry {
  const _MoreEntry({
    required this.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.route,
    this.showsUnread = false,
  });

  final Key key;
  final IconData icon;
  final String title;
  final String subtitle;
  final String route;
  final bool showsUnread;
}

class _MoreTile extends StatelessWidget {
  const _MoreTile({required this.entry});

  final _MoreEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = context.tokens;
    Widget tile(int unread) {
      return Semantics(
        button: true,
        label: unread > 0
            ? '${entry.title}, $unread unread. ${entry.subtitle}'
            : '${entry.title}. ${entry.subtitle}',
        excludeSemantics: true,
        child: Card(
          key: entry.key,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => context.push(entry.route),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: scheme.primary.withValues(alpha: 0.10),
                      borderRadius: AppRadii.lgAll,
                    ),
                    child: Icon(entry.icon, color: scheme.primary),
                  ),
                  const SizedBox(width: AppSpacing.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(entry.title, style: tokens.sectionTitle),
                        const SizedBox(height: AppSpacing.xxs),
                        Text(entry.subtitle, style: tokens.itemSubtitle),
                      ],
                    ),
                  ),
                  if (unread > 0) ...[
                    const SizedBox(width: AppSpacing.sm),
                    Container(
                      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: scheme.primary, borderRadius: AppRadii.pillAll),
                      child: Text(unread > 99 ? '99+' : '$unread', style: tokens.badge),
                    ),
                  ],
                  const SizedBox(width: AppSpacing.xs),
                  Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (!entry.showsUnread) return tile(0);
    return ValueListenableBuilder<int>(
      valueListenable: ChatHistory.unreadTotal,
      builder: (context, unread, _) => tile(unread),
    );
  }
}
