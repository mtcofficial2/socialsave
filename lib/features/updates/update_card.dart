import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/features/updates/update_controller.dart';
import 'package:social_save/shared/widgets/glass.dart';

class UpdateCard extends ConsumerWidget {
  const UpdateCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(updateControllerProvider);
    final update = state.update;
    if (update == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Update ${update.version} is ready',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'The new app downloads here and opens the Android installer.',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
              if (state.progress != null) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(value: state.progress),
              ],
              if (state.message != null) ...[
                const SizedBox(height: 8),
                Text(state.message!, style: TextStyle(color: scheme.primary, fontSize: 12)),
              ],
              const SizedBox(height: 10),
              FilledButton(
                onPressed: state.busy
                    ? null
                    : () => ref.read(updateControllerProvider.notifier).downloadAndInstall(),
                child: Text(state.busy ? 'Downloading' : 'Download update'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
