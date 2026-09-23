import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/utils/platform_detector.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/core/theme/app_colors.dart';
import 'package:social_save/features/downloader/presentation/providers/download_manager.dart';
import 'package:social_save/features/downloader/presentation/providers/preview_controller.dart';
import 'package:social_save/features/player/open_player.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/shared/models/download_ticket.dart';
import 'package:social_save/shared/models/media_format.dart';
import 'package:social_save/shared/models/media_info.dart';
import 'package:social_save/shared/widgets/compliance_notice.dart';
import 'package:social_save/shared/widgets/glass.dart';
import 'package:social_save/shared/widgets/error_banner.dart';
import 'package:social_save/shared/widgets/platform_logo.dart';
import 'package:social_save/shared/widgets/video_thumbnail.dart';

class PreviewScreen extends ConsumerStatefulWidget {
  const PreviewScreen({super.key, this.media, this.pendingUrl});

  final MediaInfo? media;
  final String? pendingUrl;

  @override
  ConsumerState<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends ConsumerState<PreviewScreen> {
  bool _starting = false;
  bool _previewing = false;
  String? _error;
  MediaInfo? _loaded;
  bool _lookup = false;

  @override
  void initState() {
    super.initState();
    _loaded = widget.media;
    final pending = widget.pendingUrl;
    if (_loaded == null && pending != null) {
      _lookup = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _lookupLink(pending));
    }
  }

  Future<void> _lookupLink(String url) async {
    try {
      final media = await ref.read(mediaRepositoryProvider).analyze(url);
      if (!mounted) return;
      setState(() {
        _loaded = media;
        _lookup = false;
      });
    } on AppException catch (error) {
      if (!mounted) return;
      setState(() {
        _lookup = false;
        _error = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _lookup = false;
        _error = 'Could not look up this link.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.pendingUrl;
    if (_loaded == null) {
      return _LookupScaffold(
        url: pending ?? '',
        error: _error,
        loading: _lookup,
        onRetry: pending == null ? null : () => _lookupLink(pending),
      );
    }
    return _PreviewBody(
      media: _loaded!,
      starting: _starting,
      previewing: _previewing,
      error: _error,
      onPlay: _playBeforeDownload,
      onDownload: (media, format) => _startDownload(media, format),
    );
  }
}

class _PreviewBody extends ConsumerWidget {
  const _PreviewBody({
    required this.media,
    required this.starting,
    required this.previewing,
    required this.error,
    required this.onPlay,
    required this.onDownload,
  });

  final MediaInfo media;
  final bool starting;
  final bool previewing;
  final String? error;
  final Future<void> Function(MediaInfo media, MediaFormat? format) onPlay;
  final Future<void> Function(MediaInfo media, MediaFormat format) onDownload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(previewControllerProvider(this.media));
    final formatters = ref.watch(formattersProvider);
    final media = preview.media;
    final format = preview.format;
    final scheme = Theme.of(context).colorScheme;
    final sizeLabel = format?.filesize != null
        ? formatters.bytes(format!.filesize)
        : 'file';

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.maybePop(context),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                const Expanded(
                  child: Text(
                    'Media Inspection Details',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.person, color: Colors.white, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'ANALYSIS COMPLETE',
                  style: TextStyle(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    letterSpacing: 0.6,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'ID: ${media.platform.letter}-${media.sourceUrl.hashCode.abs().toRadixString(16).substring(0, 5).toUpperCase()}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            GlassCard(
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      VideoThumbnail(
                        url: media.thumbnailUrl,
                        durationSeconds: media.durationSeconds,
                        height: 210,
                        borderRadius: 0,
                      ),
                      Positioned(
                        top: 12,
                        left: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            children: [
                              PlatformLogo(platform: media.platform, size: 16),
                              const SizedBox(width: 6),
                              Text(
                                '${media.platform.displayName}${media.platform.id == 'instagram' ? ' Reel' : ''}',
                                style: TextStyle(
                                  color: AppColors.platformColor(media.platform),
                                  fontWeight: FontWeight.w700,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (format?.width != null && format?.height != null)
                        Positioned(
                          top: 12,
                          right: 12,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '${format!.width} × ${format.height}',
                              style: const TextStyle(color: Colors.white, fontSize: 11),
                            ),
                          ),
                        ),
                      Positioned.fill(
                        child: Center(
                          child: Material(
                            color: Colors.white,
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: previewing || !media.canDownload
                                  ? null
                                  : () => onPlay(media, format),
                              child: SizedBox(
                                width: 64,
                                height: 64,
                                child: previewing
                                    ? const Padding(
                                        padding: EdgeInsets.all(16),
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.play_arrow_rounded, size: 36, color: AppColors.primary),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          media.title,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          [
                            if (media.author != null && media.author!.isNotEmpty)
                              '@${media.author}',
                            media.canDownload ? 'Public' : 'Restricted',
                            if (format != null) format.quality,
                          ].join('  •  '),
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 12),
                        if (media.canDownload)
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppColors.okSoft,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.verified, color: AppColors.ok, size: 20),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Verified Public Post — Safe to Archive',
                                        style: TextStyle(
                                          color: AppColors.ok,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 11,
                                        ),
                                      ),
                                      Text(
                                        'Metadata confirms creative attribution & open availability.',
                                        style: TextStyle(color: AppColors.ok, fontSize: 11),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          const ComplianceNotice(danger: true, compact: true),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                const Text(
                  'Select Quality & Format',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Icon(Icons.tune, size: 16, color: scheme.primary),
                const SizedBox(width: 4),
                Text(
                  '${media.formats.length} available',
                  style: TextStyle(color: scheme.primary, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...media.formats.map((item) {
              final selected = format?.id == item.id;
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Material(
                  color: selected
                      ? scheme.secondaryContainer.withValues(alpha: 0.22)
                      : scheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => ref
                        .read(previewControllerProvider(media).notifier)
                        .selectFormat(item),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: selected ? scheme.primary : scheme.surfaceContainerHighest,
                              shape: BoxShape.circle,
                            ),
                            child: selected
                                ? const Icon(Icons.check, size: 16, color: Colors.white)
                                : null,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        item.quality.toLowerCase() == 'original'
                                            ? 'Best Quality (${item.format.toUpperCase()})'
                                            : '${item.quality} ${item.format.toUpperCase()}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                    if (selected) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: scheme.primary,
                                          borderRadius: BorderRadius.circular(999),
                                        ),
                                        child: const Text(
                                          'Recommended',
                                          style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  item.hasVideo ? 'H.264 • ${item.format.toUpperCase()}' : 'Audio extract',
                                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                item.filesize != null ? formatters.bytes(item.filesize) : '—',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: selected ? scheme.primary : scheme.onSurface,
                                ),
                              ),
                              Text(
                                selected ? 'Instant' : 'Fast',
                                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
            if (error != null) ...[
              ErrorBanner(message: error!),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: !media.canDownload || format == null || previewing
                  ? null
                  : () => onPlay(media, format),
              icon: const Icon(Icons.play_circle_outline),
              label: Text(previewing ? 'Opening preview…' : 'Play without downloading'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: !media.canDownload || format == null || starting
                  ? null
                  : () => onDownload(media, format),
              icon: const Icon(Icons.download_rounded),
              label: Text(starting ? 'Starting…' : 'Start Download ($sizeLabel)'),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 52,
              child: FilledButton.tonal(
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.surfaceContainerLow,
                  foregroundColor: scheme.primary,
                ),
                onPressed: () => Navigator.maybePop(context),
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LookupScaffold extends StatelessWidget {
  const _LookupScaffold({
    required this.url,
    required this.loading,
    this.error,
    this.onRetry,
  });

  final String url;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final platform = const PlatformDetector().detect(url);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.maybePop(context),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                PlatformLogo(platform: platform, size: 28),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    platform == SocialPlatform.unknown
                        ? 'Looking up this link'
                        : platform.displayName,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            VideoThumbnail(url: null, height: 180, borderRadius: 16),
            const SizedBox(height: 12),
            Text(
              url,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            if (loading) const LinearProgressIndicator(),
            if (error != null) ...[
              const SizedBox(height: 12),
              ErrorBanner(message: error!, onRetry: onRetry),
            ],
          ],
        ),
      ),
    );
  }
}

extension on _PreviewScreenState {
  Future<void> _playBeforeDownload(MediaInfo media, MediaFormat? format) async {
    if (format == null) {
      setState(() => _error = 'Choose a quality first.');
      return;
    }
    setState(() {
      _previewing = true;
      _error = null;
    });
    try {
      final playFormat = media.platform.id == 'youtube' ? 'preview' : format.id;
      final ticket = await ref.read(mediaRepositoryProvider).requestDownload(
            url: media.sourceUrl,
            formatId: playFormat,
          );
      final direct = ticket.directUrl;
      final directPlayable = direct != null &&
          direct.isNotEmpty &&
          !direct.contains('onrender.com') &&
          !direct.contains('googlevideo') &&
          media.platform.id != 'youtube';
      var url = directPlayable ? direct! : ticket.downloadUrl;
      if (url.isEmpty && ticket.jobId != null) {
        for (var i = 0; i < 45; i++) {
          await Future<void>.delayed(const Duration(seconds: 2));
          final status = await ref.read(mediaRepositoryProvider).getJobStatus(ticket.jobId!);
          if ((status.downloadUrl ?? '').isNotEmpty) {
            url = status.downloadUrl!;
            break;
          }
          if (status.state == DownloadJobState.failed) {
            break;
          }
        }
      }
      if (url.isEmpty) {
        throw const AppException(
          code: AppErrorCode.platformUnavailable,
          message: 'No preview stream yet. Download the file, then play it.',
        );
      }
      if (!mounted) return;
      await openPreviewPlayer(
        context,
        PlayerSession(
          title: media.title,
          platform: media.platform,
          networkUrl: url,
          thumbnailUrl: media.thumbnailUrl,
          author: media.author,
          referer: media.sourceUrl,
          httpHeaders: ticket.requestHeaders,
          isPreview: true,
        ),
      );
    } on AppException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = 'Could not start a preview. Try downloading first.');
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
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
      if (mounted) setState(() => _starting = false);
    }
  }
}
