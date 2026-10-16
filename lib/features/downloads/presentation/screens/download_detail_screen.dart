import 'dart:io';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:social_save/shared/widgets/page_layout.dart';
import 'package:social_save/features/library/phone_handoff.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/platform/desktop_support.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/features/downloads/presentation/providers/downloads_controller.dart';
import 'package:social_save/features/library/vault_actions.dart';
import 'package:social_save/features/player/open_player.dart';
import 'package:social_save/features/home/presentation/providers/home_controller.dart';
import 'package:social_save/shared/widgets/empty_state.dart';
import 'package:social_save/shared/widgets/platform_badge.dart';
import 'package:social_save/shared/widgets/video_thumbnail.dart';

class DownloadDetailScreen extends ConsumerWidget {
  const DownloadDetailScreen({super.key, required this.id});

  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(downloadsControllerProvider);
    final formatters = ref.watch(formattersProvider);

    return history.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Scaffold(
        appBar: AppBar(title: const Text('Saved video')),
        body: EmptyState(
          icon: Icons.error_outline_rounded,
          title: 'Could not open this download',
          message: '$error',
        ),
      ),
      data: (records) {
        final record = records.where((item) => item.id == id).firstOrNull;
        if (record == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Saved video')),
            body: const EmptyState(
              icon: Icons.video_library_outlined,
              title: 'This download was removed',
              message: 'It is no longer in your history.',
            ),
          );
        }
        final controller = ref.read(downloadsControllerProvider.notifier);
        final scheme = Theme.of(context).colorScheme;
        Widget fact(IconData icon, String text) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(text, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
            ],
          );
        }
        return Scaffold(
          appBar: AppBar(title: const Text('Saved video')),
          body: ListView(
            padding: pagePadding(context, top: 8, bottom: 32),
            children: [
              VideoThumbnail(
                url: record.thumbnailUrl,
                durationSeconds: record.durationSeconds,
                height: 200,
              ),
              const SizedBox(height: 16),
              PlatformBadge(platform: record.platform),
              const SizedBox(height: 8),
              Text(
                record.title,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                      height: 1.25,
                    ),
              ),
              if (record.author != null && record.author!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(record.author!, style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  fact(Icons.event_outlined, formatters.date(record.downloadedAt)),
                  fact(Icons.sd_storage_outlined, formatters.bytes(record.fileSize)),
                ],
              ),
              if (record.localPath != null && !kIsWeb) ...[
                const SizedBox(height: 16),
                Text(
                  'Saved file',
                  style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurface),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  record.localPath!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _guard(
                        context,
                        () => controller.share(record),
                      ),
                      icon: const Icon(Icons.ios_share),
                      label: const Text('Share'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => openInAppPlayer(context, record),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Play'),
                    ),
                  ),
                ],
              ),
              if (DesktopSupport.isWindows && record.localPath != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => DesktopSupport.revealInFolder(record.localPath!),
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('Show in folder'),
                ),
              ],
              // Web: sending to a device and the Vault are app-only.
              if (!kIsWeb) ...[
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: record.localPath == null
                      ? null
                      : () => showSendToPhone(context, File(record.localPath!), record.title),
                  icon: const Icon(Icons.send_to_mobile_rounded),
                  label: const Text('Send to another phone or PC'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: record.localPath == null
                      ? null
                      : () => moveDownloadToVault(context, ref, record),
                  icon: const Icon(Icons.lock_outline),
                  label: const Text('Move to vault'),
                ),
              ],
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: record.sourceUrl));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Link copied. You can download it again later.')),
                    );
                  }
                },
                icon: const Icon(Icons.link_rounded),
                label: const Text('Copy link'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () {
                  ref.read(homeControllerProvider.notifier).setUrl(record.sourceUrl);
                  context.go('/');
                },
                icon: const Icon(Icons.download_outlined),
                label: const Text('Download again'),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () async {
                  await controller.delete(record.id, deleteFile: true);
                  if (context.mounted) {
                    context.go('/downloads');
                  }
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _guard(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } on AppException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    }
  }
}
