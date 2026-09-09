import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/features/downloader/presentation/providers/download_manager.dart';
import 'package:social_save/features/downloader/presentation/providers/preview_controller.dart';
import 'package:social_save/shared/models/media_format.dart';
import 'package:social_save/shared/models/media_info.dart';
import 'package:social_save/shared/widgets/compliance_notice.dart';
import 'package:social_save/shared/widgets/error_banner.dart';
import 'package:social_save/shared/widgets/platform_badge.dart';
import 'package:social_save/shared/widgets/quality_selector.dart';
import 'package:social_save/shared/widgets/video_thumbnail.dart';

class PreviewScreen extends ConsumerStatefulWidget {
  const PreviewScreen({super.key, required this.media});

  final MediaInfo media;

  @override
  ConsumerState<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends ConsumerState<PreviewScreen> {
  bool _starting = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final preview = ref.watch(previewControllerProvider(widget.media));
    final formatters = ref.watch(formattersProvider);
    final media = preview.media;
    final format = preview.format;
    final formats = media.formats.map((item) => item.format).toSet().toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Download')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          VideoThumbnail(
            url: media.thumbnailUrl,
            durationSeconds: media.durationSeconds,
            height: 210,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              PlatformBadge(platform: media.platform),
              const Spacer(),
              if (media.durationSeconds != null)
                Text(formatters.duration(media.durationSeconds)),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            media.title,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          if (media.author != null && media.author!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              media.author!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            format?.filesize != null
                ? 'Estimated size ${formatters.bytes(format!.filesize)}'
                : 'File size will be confirmed when the download starts.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          Text('Quality', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          QualitySelector(
            formats: media.formats,
            selected: format,
            onSelected: (value) => ref
                .read(previewControllerProvider(widget.media).notifier)
                .selectFormat(value),
          ),
          if (formats.length > 1) ...[
            const SizedBox(height: 16),
            Text('Format', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            FormatSelector(
              formats: formats,
              selected: format?.format,
              onSelected: (value) {
                final match = media.formats.firstWhere(
                  (item) =>
                      item.format.toLowerCase() == value.toLowerCase() &&
                      (format == null ||
                          item.quality == format.quality ||
                          item.id == format.id),
                  orElse: () => media.formats.firstWhere(
                    (item) => item.format.toLowerCase() == value.toLowerCase(),
                    orElse: () => media.formats.first,
                  ),
                );
                ref
                    .read(previewControllerProvider(widget.media).notifier)
                    .selectFormat(match);
              },
            ),
          ],
          const SizedBox(height: 20),
          if (!media.canDownload)
            ErrorBanner(
              message: media.downloadRestrictedReason ??
                  'This platform does not permit downloading through SocialSave.',
            ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            ErrorBanner(message: _error!),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: !media.canDownload || format == null || _starting
                ? null
                : () => _startDownload(media, format),
            icon: _starting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_rounded),
            label: Text(_starting ? 'Starting…' : 'Download'),
          ),
          const SizedBox(height: 16),
          const ComplianceNotice(),
        ],
      ),
    );
  }

  Future<void> _startDownload(MediaInfo media, MediaFormat format) async {
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final task = await ref.read(downloadManagerProvider.notifier).enqueue(
            media: media,
            format: format,
          );
      if (mounted) {
        await context.push('/progress/${task.id}');
      }
    } on AppException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = 'Could not start the download.');
    } finally {
      if (mounted) {
        setState(() => _starting = false);
      }
    }
  }
}
