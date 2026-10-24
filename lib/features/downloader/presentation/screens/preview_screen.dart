import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:social_save/core/engine/phone_engine.dart';
import 'package:social_save/shared/widgets/skeleton.dart';
import 'package:social_save/core/config/hosted_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/shared/widgets/page_layout.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/utils/platform_detector.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/core/theme/app_colors.dart';
import 'package:social_save/features/downloader/presentation/providers/download_manager.dart';
import 'package:social_save/features/home/presentation/widgets/link_offer.dart';
import 'package:social_save/features/downloader/presentation/providers/preview_controller.dart';
import 'package:social_save/features/player/open_player.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/features/player/preview_timing.dart';
import 'package:social_save/features/downloader/domain/repositories/media_repository.dart';
import 'package:social_save/shared/models/download_ticket.dart';
import 'package:social_save/shared/models/media_format.dart';
import 'package:social_save/shared/models/media_info.dart';
import 'package:social_save/shared/widgets/compliance_notice.dart';
import 'package:social_save/shared/widgets/glass.dart';
import 'package:social_save/shared/widgets/error_banner.dart';
import 'package:social_save/shared/widgets/platform_badge.dart';
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
        onTryServer: pending == null || !PhoneEngine.isEngineMessage(_error)
            ? null
            : () {
                PhoneEngine.useServerFor(pending);
                setState(() {
                  _error = null;
                  _lookup = true;
                });
                _lookupLink(pending);
              },
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
          padding: pagePadding(context, top: 4),
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.maybePop(context),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                Expanded(
                  child: Text(
                    'Preview',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                  ),
                ),
                StatusBadge(
                  label: media.canDownload ? 'Public' : 'Restricted',
                  kind: media.canDownload ? StatusBadgeKind.public : StatusBadgeKind.restricted,
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
                        height: isDesktopShell(context) ? 380 : 210,
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
                                  fontSize: 12,
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
                              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
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
                            if (format != null) format.displayQuality,
                          ].join('  •  '),
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 12),
                        if (media.canDownload)
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppColors.successBg(Theme.of(context).brightness),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.verified_outlined, color: AppColors.successFg(Theme.of(context).brightness), size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Public link',
                                        style: TextStyle(
                                          color: AppColors.successFg(Theme.of(context).brightness),
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13,
                                        ),
                                      ),
                                      Text(
                                        'You can save this. SocialSave does not bypass logins or DRM.',
                                        style: TextStyle(
                                          color: AppColors.successFg(Theme.of(context).brightness),
                                          fontSize: 12,
                                          height: 1.35,
                                        ),
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
                                ? Icon(Icons.check, size: 16, color: scheme.onPrimary)
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
                                            : '${item.displayQuality} ${item.format.toUpperCase()}',
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
                                        child: Text(
                                          'Selected',
                                          style: TextStyle(color: scheme.onPrimary, fontSize: 12, fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  item.hasVideo ? item.format.toUpperCase() : 'Audio',
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
                                item.hasVideo ? 'Video' : 'Audio',
                                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
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
    this.onTryServer,
  });

  final String url;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;
  final VoidCallback? onTryServer;

  @override
  Widget build(BuildContext context) {
    final platform = const PlatformDetector().detect(url);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: pagePadding(context, top: 4),
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
            if (loading && _QuickLook.idOf(url) != null)
              _QuickLook(url: url)
            else if (loading)
              // Shaped like the preview that is coming (1.0.37), instead of a
              // grey box and a bar.
              const SkeletonBox(height: 180, radius: 16)
            else
              VideoThumbnail(url: null, height: 180, borderRadius: 16),
            const SizedBox(height: 12),
            Text(
              url,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            if (loading) ...[
              const SizedBox(height: 16),
              const SkeletonBox(height: 20, width: 260, radius: 6),
              const SizedBox(height: 8),
              const SkeletonBox(height: 14, width: 160, radius: 6),
              const SizedBox(height: 20),
              Row(
                children: const [
                  Expanded(child: SkeletonBox(height: 44)),
                  SizedBox(width: 8),
                  Expanded(child: SkeletonBox(height: 44)),
                  SizedBox(width: 8),
                  Expanded(child: SkeletonBox(height: 44)),
                ],
              ),
              const SizedBox(height: 16),
              const SkeletonBox(height: 52, radius: 14),
              const SizedBox(height: 12),
              Text(
                'Reading video details…',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 12),
              ErrorBanner(message: error!, onRetry: onRetry, onTryServer: onTryServer),
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
      final (url, ticket) = await resolvePreviewStream(ref.read(mediaRepositoryProvider), media, format);
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
          audioUrl: ticket.audioUrl,
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
      if (mounted && await showAlreadySaved(context, error)) return;
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      setState(() => _error = 'Could not start the download.');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }
}

/// Preview stream for [media]: the URL to play and the ticket it came from.
/// Shared by the Preview button and the `--preview-test` hook.
Future<(String, DownloadTicket)> resolvePreviewStream(MediaRepository repo, MediaInfo media, MediaFormat format) async {
  PreviewTiming.start(media.sourceUrl);
  // 1.0.45: ask for the engine's "preview" stream (one muxed file, up to
  // 720p, straight from the site) instead of the chosen download format,
  // which for split video+audio waited for the whole file to be merged.
  DownloadTicket ticket;
  if (PreviewTiming.legacy) {
    ticket = await repo.requestDownload(url: media.sourceUrl, formatId: format.id);
  } else {
    try {
      ticket = await repo.requestDownload(url: media.sourceUrl, formatId: 'preview');
    } on AppException {
      ticket = await repo.requestDownload(url: media.sourceUrl, formatId: format.id);
    }
  }
  PreviewTiming.mark('ticket');
  final direct = ticket.directUrl;
  final directPlayable = !kIsWeb &&
      direct != null &&
      direct.isNotEmpty &&
      !HostedApi.matches(direct);
  var url = directPlayable ? direct! : ticket.downloadUrl;
  if (url.isEmpty && ticket.jobId != null) {
    // Check often: a short clip is ready in a second or two.
    for (var i = 0; i < 180; i++) {
      await Future<void>.delayed(Duration(milliseconds: PreviewTiming.legacy ? 2000 : 500));
      final status = await repo.getJobStatus(ticket.jobId!);
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
    PreviewTiming.stop('no-stream');
    throw const AppException(
      code: AppErrorCode.platformUnavailable,
      message: 'No preview stream yet. Download the file, then play it.',
    );
  }
  PreviewTiming.mark('url');
  return (url, ticket);
}

/// YouTube thumbnail at once (built from the video id) and the title from
/// oEmbed in about a second, while the phone engine reads the formats.
class _QuickLook extends StatefulWidget {
  const _QuickLook({required this.url});

  final String url;

  static final _id = RegExp(r'(?:youtu\.be/|[?&]v=|/(?:shorts|embed|live|v)/)([A-Za-z0-9_-]{11})');

  static String? idOf(String url) {
    if (!url.contains('youtu')) return null;
    return _id.firstMatch(url)?.group(1);
  }

  @override
  State<_QuickLook> createState() => _QuickLookState();
}

class _QuickLookState extends State<_QuickLook> {
  String? _title;
  String? _author;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 4),
        receiveTimeout: const Duration(seconds: 4),
      ));
      final res = await dio.get<Map<String, dynamic>>(
        'https://www.youtube.com/oembed',
        queryParameters: {'url': widget.url, 'format': 'json'},
      );
      final data = res.data;
      if (!mounted || data == null) return;
      setState(() {
        _title = data['title'] as String?;
        _author = data['author_name'] as String?;
      });
    } catch (_) {
      // The full lookup still fills in the title.
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = _QuickLook.idOf(widget.url)!;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        VideoThumbnail(
          url: 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
          height: 180,
          borderRadius: 16,
        ),
        if (_title != null) ...[
          const SizedBox(height: 12),
          Text(
            _title!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          if (_author != null)
            Text(_author!, style: TextStyle(color: scheme.onSurfaceVariant)),
        ],
      ],
    );
  }
}