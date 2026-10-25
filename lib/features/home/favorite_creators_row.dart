import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/features/home/favorite_creators.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/widgets/platform_logo.dart';

/// Saved channels and profiles. Tap opens the set. Long-press removes one.
class FavoriteCreatorsRow extends ConsumerWidget {
  const FavoriteCreatorsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(favoriteCreatorsProvider);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Creators',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        if (people.isEmpty)
          Text(
            'Open a YouTube channel or TikTok profile and tap Save this creator. The name and picture stay here.',
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35, fontSize: 13),
          )
        else
          SizedBox(
            height: 112,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: people.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final person = people[index];
                return _CreatorChip(person: person);
              },
            ),
          ),
      ],
    );
  }
}

class _CreatorChip extends ConsumerWidget {
  const _CreatorChip({required this.person});

  final FavoriteCreator person;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 76,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => context.push('/playlist', extra: person.url),
        onLongPress: () async {
          final remove = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Remove this creator?'),
              content: Text(person.name),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
                TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove')),
              ],
            ),
          );
          if (remove == true) {
            await ref.read(favoriteCreatorsProvider.notifier).remove(person.url);
          }
        },
        child: Column(
          children: [
            _Face(name: person.name, avatarUrl: person.avatarUrl, platform: person.platform),
            const SizedBox(height: 6),
            Text(
              person.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, height: 1.2, color: scheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}

class _Face extends StatelessWidget {
  const _Face({required this.name, required this.avatarUrl, required this.platform});

  final String name;
  final String? avatarUrl;
  final String platform;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final letter = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    final known = SocialPlatform.fromId(platform);
    return SizedBox(
      width: 64,
      height: 64,
      child: Stack(
        children: [
          ClipOval(
            child: avatarUrl == null
                ? ColoredBox(
                    color: scheme.primaryContainer,
                    child: Center(
                      child: Text(
                        letter,
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  )
                : CachedNetworkImage(
                    imageUrl: avatarUrl!,
                    width: 64,
                    height: 64,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => ColoredBox(
                      color: scheme.primaryContainer,
                      child: Center(
                        child: Text(
                          letter,
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: scheme.onPrimaryContainer),
                        ),
                      ),
                    ),
                  ),
          ),
          if (known != SocialPlatform.unknown && known != SocialPlatform.web)
            Positioned(
              right: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface,
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: PlatformLogo(platform: known, size: 14),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
