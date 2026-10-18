import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/core/notifications/notification_service.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/core/utils/platform_detector.dart';
import 'package:social_save/core/utils/url_validator.dart';
import 'package:social_save/features/downloader/presentation/providers/download_manager.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';
import 'package:social_save/shared/models/media_info.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/routing/app_router.dart';
import 'package:window_manager/window_manager.dart';

final _urlInText = RegExp(r'https?://[^\s<>"]+', caseSensitive: false);
const _lastKey = 'linkoffer.last';

/// A public video link found in [raw], or null for anything else.
String? videoLinkIn(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return null;
  const validator = UrlValidator();
  var r = validator.validate(text);
  if (!r.isValid) {
    final m = _urlInText.firstMatch(text);
    if (m == null) return null;
    r = validator.validate(m.group(0)!);
  }
  if (!r.isValid) return null;
  final url = r.normalized.toString();
  return const PlatformDetector().detect(url) == SocialPlatform.unknown ? null : url;
}

String _clock(int s) {
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, x = s % 60;
  final ss = x.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

/// Shows the quiet "Download this video?" sheet (phone) or dialog (desktop).
/// It analyses [url] first. [auto] keeps failures silent.
Future<void> offerLink(String url, {bool auto = false}) async {
  final ctx = appRouter.routerDelegate.navigatorKey.currentContext;
  if (ctx == null || !ctx.mounted) return;
  final wide = MediaQuery.sizeOf(ctx).width >= 700;
  final sheet = _OfferSheet(url: url, auto: auto);
  if (wide) {
    await showDialog<void>(
      context: ctx,
      builder: (_) => Dialog(
        backgroundColor: Theme.of(ctx).colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 440), child: sheet),
      ),
    );
  } else {
    await showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      showDragHandle: false,
      backgroundColor: Theme.of(ctx).colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      builder: (_) => sheet,
    );
  }
}

class _OfferSheet extends ConsumerStatefulWidget {
  const _OfferSheet({required this.url, required this.auto});

  final String url;
  final bool auto;

  @override
  ConsumerState<_OfferSheet> createState() => _OfferSheetState();
}

class _OfferSheetState extends ConsumerState<_OfferSheet> {
  MediaInfo? _media;
  String? _error;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final m = await ref.read(mediaRepositoryProvider).analyze(widget.url);
      if (!mounted) return;
      setState(() => _media = m);
    } on AppException catch (e) {
      _fail(e.message);
    } catch (_) {
      _fail('Could not read this link.');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    if (widget.auto) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _error = message);
  }

  Future<void> _download() async {
    final media = _media;
    final format = media?.defaultFormat;
    if (media == null || format == null || _starting) return;
    HapticFeedback.lightImpact();
    setState(() => _starting = true);
    try {
      final task = await ref.read(downloadManagerProvider.notifier).enqueue(media: media, format: format);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop();
      messenger?.showSnackBar(SnackBar(
        content: const Text('Downloading'),
        action: SnackBarAction(label: 'View', onPressed: () => appRouter.push('/progress/${task.id}')),
      ));
    } on AppException catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _starting = false;
          _error = 'Could not start the download.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurface.withValues(alpha: 0.55);
    final media = _media;
    final canDownload = media != null && media.canDownload && media.defaultFormat != null;
    Widget body;
    if (media == null && _error == null) {
      body = SizedBox(
        height: 120,
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(height: 14),
            Text('Checking link', style: TextStyle(color: muted, fontSize: 13)),
          ]),
        ),
      );
    } else if (media == null) {
      body = SizedBox(
        height: 90,
        child: Center(child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: muted))),
      );
    } else {
      final dur = media.durationSeconds;
      final meta = [
        media.platform.displayName,
        if (dur != null && dur > 0) _clock(dur),
        if (media.defaultFormat != null) media.defaultFormat!.quality,
      ].join('  ·  ');
      body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (media.thumbnailUrl != null && media.thumbnailUrl!.isNotEmpty)
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.network(
                media.thumbnailUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => ColoredBox(color: scheme.surfaceContainerHigh),
              ),
            ),
          ),
        const SizedBox(height: 16),
        Text(
          media.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.3),
        ),
        const SizedBox(height: 4),
        Text(meta, style: TextStyle(fontSize: 13, color: muted)),
        if (!canDownload && media.downloadRestrictedReason != null) ...[
          const SizedBox(height: 8),
          Text(media.downloadRestrictedReason!, style: TextStyle(fontSize: 12.5, color: muted)),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(fontSize: 12.5, color: scheme.error)),
        ],
      ]);
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            'Download this video?',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w400, color: scheme.onSurface),
          ),
          const SizedBox(height: 16),
          body,
          const SizedBox(height: 22),
          Row(children: [
            Expanded(
              child: TextButton(
                onPressed: _starting ? null : () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: const StadiumBorder()),
                child: const Text('Not now'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: canDownload && !_starting ? _download : null,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: const StadiumBorder()),
                child: _starting
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Download'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// Watches the clipboard for a copied video link: when the app opens or
/// resumes, and on Windows every couple of seconds while running (also from
/// the tray, where it raises a toast with Download / Dismiss instead).
class LinkOfferWatcher extends ConsumerStatefulWidget {
  const LinkOfferWatcher({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LinkOfferWatcher> createState() => _LinkOfferWatcherState();
}

class _LinkOfferWatcherState extends ConsumerState<LinkOfferWatcher> with WidgetsBindingObserver {
  Timer? _timer;
  String? _seen;
  bool _busy = false;
  bool _open = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotificationService.onResponse = _onToast;
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_check()));
    if (Plat.isWindows) {
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_check()));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (NotificationService.onResponse == _onToast) NotificationService.onResponse = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  Future<bool> _windowActive() async {
    if (!Plat.isWindows) return true;
    try {
      return await windowManager.isVisible() &&
          !await windowManager.isMinimized() &&
          await windowManager.isFocused();
    } catch (_) {
      return true;
    }
  }

  Future<void> _check() async {
    if (_busy || _open || Plat.isWeb) return;
    if (!ref.read(settingsControllerProvider).offerCopiedLinks) return;
    _busy = true;
    try {
      final loc = appRouter.routerDelegate.currentConfiguration.uri.path;
      if (loc.startsWith('/player')) return;
      String? text;
      try {
        text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      } catch (_) {
        return;
      }
      final url = videoLinkIn(text);
      if (url == null || url == _seen) return;
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_lastKey) == url) {
        _seen = url;
        return;
      }
      _seen = url;
      await prefs.setString(_lastKey, url);
      if (await _windowActive()) {
        _open = true;
        try {
          await offerLink(url, auto: true);
        } finally {
          _open = false;
        }
      } else {
        var host = url;
        try {
          host = Uri.parse(url).host.replaceFirst('www.', '');
        } catch (_) {}
        await ref.read(notificationServiceProvider).showLinkOffer(url: url, subtitle: host);
      }
    } finally {
      _busy = false;
    }
  }

  /// A Windows toast was tapped: "download|url", "dismiss|url" or the body.
  void _onToast(String? actionId, String? payload) {
    final raw = (actionId != null && actionId.contains('|')) ? actionId : payload;
    if (raw == null || raw.isEmpty) return;
    final parts = raw.split('|');
    final isDownload = parts.first == 'download';
    final isDismiss = parts.first == 'dismiss';
    final url = parts.length > 1 ? parts.sublist(1).join('|') : raw;
    if (isDismiss) return;
    unawaited(() async {
      if (isDownload) {
        try {
          final media = await ref.read(mediaRepositoryProvider).analyze(url);
          final format = media.defaultFormat;
          if (format != null && media.canDownload) {
            await ref.read(downloadManagerProvider.notifier).enqueue(media: media, format: format);
            return;
          }
        } catch (_) {}
      }
      try {
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
      await offerLink(url);
    }());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
