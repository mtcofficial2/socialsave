import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/features/home/presentation/providers/home_controller.dart';
import 'package:social_save/features/home/presentation/providers/save_queue.dart';

class SaveQueueSection extends ConsumerWidget {
  const SaveQueueSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(saveQueueProvider);
    final url = ref.watch(homeControllerProvider.select((state) => state.url));
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: url.trim().isEmpty
              ? null
              : () => ref.read(saveQueueProvider.notifier).add(url),
          icon: const Icon(Icons.playlist_add_rounded),
          label: const Text('Add to queue'),
        ),
        if (items.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'Queue',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          ...items.map((item) {
            final label = switch (item.phase) {
              SavePhase.waiting => 'Waiting',
              SavePhase.saving => 'Saving',
              SavePhase.done => 'Done',
              SavePhase.failed => 'Failed',
            };
            return Card(
              child: ListTile(
                title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(item.detail ?? item.url, maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: Text(
                  label,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: item.phase == SavePhase.failed ? scheme.error : scheme.primary,
                  ),
                ),
              ),
            );
          }),
        ],
      ],
    );
  }
}
