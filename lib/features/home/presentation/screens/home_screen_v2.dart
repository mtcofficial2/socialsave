import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/config/build_flags.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/network/dio_client.dart';
import 'package:social_save/core/platform/desktop_support.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/core/storage/storage_migration.dart';
import 'package:social_save/core/storage/vault_recovery.dart';
import 'package:social_save/features/downloader/follow_creator.dart';
import 'package:social_save/features/home/favorite_creators_row.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/downloads/presentation/providers/downloads_controller.dart';
import 'package:social_save/features/home/presentation/providers/home_controller.dart';
import 'package:social_save/features/home/presentation/providers/save_queue.dart';
import 'package:social_save/features/home/presentation/screens/home_screen.dart';
import 'package:social_save/features/home/presentation/widgets/save_queue_section.dart';
import 'package:social_save/features/home/presentation/widgets/supported_platforms.dart';
import 'package:social_save/features/home/presentation/widgets/url_input_card.dart';
import 'package:social_save/core/utils/set_link.dart';
import 'package:social_save/features/home/presentation/widgets/link_offer.dart';
import 'package:social_save/features/library/app_share.dart';
import 'package:social_save/features/library/hotspot_share.dart';
import 'package:social_save/features/library/phone_handoff.dart';
import 'package:social_save/features/library/presentation/library_screen.dart'
    show vaultServiceProvider;
import 'package:social_save/features/player/open_player.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';
import 'package:social_save/features/updates/update_card.dart';
import 'package:social_save/shared/widgets/app_logo.dart';
import 'package:social_save/shared/widgets/compliance_notice.dart';
import 'package:social_save/shared/widgets/page_layout.dart';
import 'package:social_save/shared/widgets/platform_logo.dart';
import 'package:social_save/shared/widgets/video_thumbnail.dart';
import 'package:social_save/web/web_relay.dart';
import 'package:social_save/shared/widgets/app_snack.dart';
import 'package:social_save/core/theme/app_tokens.dart';

/// Picks the Home screen live: the new one, or the old one when
/// Settings > Appearance > "Classic home screen" is on.
class HomeGate extends ConsumerWidget {
  const HomeGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final classic = ref.watch(settingsControllerProvider.select((s) => s.classicHome));
    return classic ? const HomeScreen() : const HomeScreenV2();
  }
}

/// Premium, minimal Home: one calm primary area, quick actions, recent list.
class HomeScreenV2 extends ConsumerStatefulWidget {
  const HomeScreenV2({super.key});

  @override
  ConsumerState<HomeScreenV2> createState() => _HomeScreenV2State();
}

class _HomeScreenV2State extends ConsumerState<HomeScreenV2> with WidgetsBindingObserver {
  static bool _receiveHandled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Plat.isAndroid) unawaited(InstalledApps.warm());
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (Plat.isWeb) {
        final code = Uri.base.queryParameters['receive'];
        if (!_receiveHandled && code != null && code.trim().isNotEmpty && mounted) {
          _receiveHandled = true;
          await showRelayReceive(context, code: code.trim().toUpperCase());
        }
        return;
      }
      final repo = ref.read(downloadsRepositoryProvider);
      final vault = ref.read(vaultServiceProvider);
      unawaited(() async {
        await StorageMigration.run(repo, vault: vault);
        await VaultRecovery.run(vault, repo);
      }());
      await _onArrive();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !Plat.isWeb) unawaited(_onArrive());
  }

  Future<void> _onArrive() async {
    if (!mounted) return;
    unawaited(FollowCreator.checkIfDue(ProviderScope.containerOf(context, listen: false)));
    if (await _consumeShare()) return;
    await _importClipboard();
  }

  Future<bool> _consumeShare() async {
    if (!mounted) return false;
    if (DesktopSupport.isWindows) return false;
    const channel = MethodChannel('socialsave/media');
    String? setUrl;
    try {
      setUrl = await channel.invokeMethod<String>('consumeSharedSet');
    } catch (_) {}
    if (setUrl != null && setUrl.trim().isNotEmpty && mounted) {
      final target = setUrl.trim();
      if (isPublicSet(target) || target.startsWith('http')) {
        context.push('/playlist', extra: target);
        return true;
      }
    }
    String? text;
    try {
      text = await channel.invokeMethod<String>('consumeSharedText');
    } catch (_) {
      return false;
    }
    if (text == null || text.trim().isEmpty || !mounted) return false;
    if (_brought(text)) return true;
    ref.read(homeControllerProvider.notifier).setUrl(text);
    final url = ref.read(homeControllerProvider.notifier).validatedUrl();
    if (url == null || !mounted) return false;
    if (isPublicSet(url)) {
      context.push('/playlist', extra: url);
      return true;
    }
    HapticFeedback.lightImpact();
    unawaited(offerLink(url));
    return true;
  }

  Future<void> _openPreview(Object extra) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await context.push('/preview', extra: extra);
    if (mounted && !Plat.isWindows) FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<void> _importClipboard() async {
    if (!mounted) return;
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    // A copied link is offered by LinkOfferWatcher (quiet sheet), not auto-opened.
    if (mounted) await ref.read(homeControllerProvider.notifier).refreshClipboardOffer();
  }

  /// Starts every video link in [raw] when there are at least two.
  bool _brought(String? raw) {
    final n = ref.read(saveQueueProvider.notifier).addBrought(raw);
    if (n < 2) return false;
    ref.read(homeControllerProvider.notifier).setUrl('');
    if (mounted) {
      AppSnack.info(context, 'Saving $n links.');
    }
    return true;
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (_brought(data?.text)) return;
    await ref.read(homeControllerProvider.notifier).pasteFromClipboard();
    if (!mounted) return;
    final state = ref.read(homeControllerProvider);
    if (state.error != null || state.url.isEmpty) return;
    HapticFeedback.lightImpact();
    final url = ref.read(homeControllerProvider.notifier).validatedUrl() ?? state.url;
    if (isPublicSet(url)) {
      await context.push('/playlist', extra: url);
      return;
    }
    if (kIsWeb && !await _confirmDownload(state.url)) return;
    if (!mounted) return;
    await _openPreview(state.url);
  }

  Future<bool> _confirmDownload(String url) async {
    final scheme = Theme.of(context).colorScheme;
    final yes = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        icon: Icon(Icons.download_rounded, color: scheme.primary),
        title: const Text('Download this video?'),
        content: Text(url, maxLines: 3, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Download')),
        ],
      ),
    );
    return yes == true;
  }

  Future<void> _analyze() async {
    if (_brought(ref.read(homeControllerProvider).url)) return;
    final url = ref.read(homeControllerProvider.notifier).validatedUrl();
    if (url == null || !mounted) return;
    HapticFeedback.lightImpact();
    if (isPublicSet(url)) {
      await context.push('/playlist', extra: url);
      return;
    }
    await _openPreview(url);
  }

  @override
  Widget build(BuildContext context) {
    final body = Scaffold(
      body: SafeArea(bottom: false, 
        child: LayoutBuilder(
          builder: (context, c) {
            final wide = !Plat.isWeb && c.maxWidth >= kDesktopSplitWidth;
            return wide ? _wide(context) : _narrow(context);
          },
        ),
      ),
    );
    if (Plat.isWindows) {
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyV, control: true): () => unawaited(_paste()),
        },
        child: Focus(autofocus: true, child: body),
      );
    }
    return body;
  }

  String _hello() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  Widget _header(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tag = AppConstants.appTagline.endsWith('.') ? AppConstants.appTagline : '${AppConstants.appTagline}.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const AppLogo(size: 52),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _hello(),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: scheme.primary),
                ),
                const SizedBox(height: 2),
                Semantics(
                  header: true,
                  child: Text(
                    'Save a video',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.8,
                          height: 1.05,
                        ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(tag, style: TextStyle(fontSize: 14, height: 1.35, color: scheme.onSurfaceVariant)),
                if (DesktopSupport.isWindows)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('Ctrl+V pastes a link.', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _primary(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return [
      UrlInputCard(onAnalyze: _analyze, onPaste: _paste),
      const SizedBox(height: AppSpacing.lg),
      const FavoriteCreatorsRow(),
      _wakingRow(scheme),
    ];
  }

  Widget _narrow(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          // Clears the floating nav pill plus the system inset.
          padding: EdgeInsets.fromLTRB(20, 0, 20, math.max(120, 32 + MediaQuery.paddingOf(context).bottom)),
          children: [
            _header(context),
            const UpdateCard(),
            ..._primary(context),
            const SaveQueueSection(),
            const SizedBox(height: 28),
            const _RecentSection(),
            const SizedBox(height: 20),
            const _HomeTools(),
            const SizedBox(height: 28),
            const SupportedPlatformsSection(),
            const SizedBox(height: AppSpacing.lg),
            const ComplianceNotice(compact: true),
            SizedBox(height: scheme.brightness == Brightness.dark ? 8 : 4),
          ],
        ),
      ),
    );
  }

  Widget _wide(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 8, 36, 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 6,
            child: ListView(
              padding: const EdgeInsets.only(right: 8, bottom: 16),
              children: [
                _header(context),
                const UpdateCard(),
                ..._primary(context),
                const SaveQueueSection(),
                const SizedBox(height: AppSpacing.xl),
                const ComplianceNotice(compact: true),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.xxl),
          Expanded(
            flex: 5,
            child: ListView(
              padding: const EdgeInsets.only(top: 28, bottom: 16),
              children: [
                const _RecentSection(),
                const SizedBox(height: 20),
                const _HomeTools(),
                const SizedBox(height: 28),
                const SupportedPlatformsSection(),
                SizedBox(height: scheme.brightness == Brightness.dark ? 8 : 4),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _wakingRow(ColorScheme scheme) {
    return ValueListenableBuilder<bool>(
      valueListenable: DioClient.waking,
      builder: (context, waking, _) => !waking
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      kLocalEngine
                          ? 'Starting the download engine on this PC…'
                          : 'Starting the SocialSave server. The first save through the server can take a moment.',
                      style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// Quiet tools under Recent. The paste field stays the only large control.
class _HomeTools extends ConsumerWidget {
  const _HomeTools();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final minimal = ref.watch(settingsControllerProvider.select((s) => s.minimalShortcuts));
    final scan = HotspotShare.supported ? 'Scan QR' : 'Receive';
    final items = <_QuickItem>[
      _QuickItem(Icons.swap_horiz_rounded, 'Send', 'Send files to a nearby phone or PC', () => context.push('/share'), const Color(0xFF2563EB)),
      _QuickItem(Icons.forum_rounded, 'Chats', 'Message people by username', () => context.push('/chat'), const Color(0xFF4F46E5)),
      _QuickItem(Icons.movie_filter_rounded, 'Status', 'Prepare an HD WhatsApp status', () => context.push('/status'), const Color(0xFF7C3AED)),
      if (HotspotShare.hostSupported)
        _QuickItem(Icons.wifi_tethering_rounded, 'Hotspot', 'Hotspot share', () => showHotspotQuickShare(context), const Color(0xFF0891B2)),
      _QuickItem(Icons.public_rounded, 'Browse', 'Browse sites and download videos', () => context.push('/browse'), const Color(0xFF0284C7)),
      _QuickItem(Icons.library_music_rounded, 'Music', 'Open music player', () => context.push('/music'), const Color(0xFFDB2777)),
      _QuickItem(Icons.video_library_rounded, 'Library', 'Open library', () => context.go('/library'), const Color(0xFF1D4ED8)),
      _QuickItem(Icons.qr_code_scanner_rounded, scan, 'Scan a QR code to join', () => showReceiveFromPhone(context), const Color(0xFF0EA5E9)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            'Tools',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4, color: scheme.onSurface),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'Send files, chat, and play what you saved.',
          style: TextStyle(fontSize: 13, height: 1.35, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.sm),
        LayoutBuilder(
          builder: (context, constraints) {
            const columns = 4;
            const gap = 8.0;
            final tileW = (constraints.maxWidth - gap * (columns - 1)) / columns;
            return Wrap(
              spacing: gap,
              runSpacing: 4,
              children: [
                for (final item in items)
                  SizedBox(
                    width: tileW,
                    child: minimal ? _MinimalQuickTile(item: item) : _QuickTile(item: item),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _QuickItem {
  const _QuickItem(this.icon, this.label, this.semantics, this.onTap, this.tint);
  final IconData icon;
  final String label;
  final String semantics;
  final VoidCallback onTap;
  final Color tint;
}

BoxDecoration _softPanel(ColorScheme scheme, {Color? glow}) {
  final dark = scheme.brightness == Brightness.dark;
  return BoxDecoration(
    color: dark ? scheme.surfaceContainerLow : const Color(0xF8FFFFFF),
    borderRadius: BorderRadius.circular(22),
    border: Border.all(
      color: dark ? Colors.white.withValues(alpha: 0.07) : scheme.outline.withValues(alpha: 0.85),
    ),
    boxShadow: [
      if (!dark)
        BoxShadow(
          color: (glow ?? scheme.primary).withValues(alpha: 0.08),
          blurRadius: 18,
          offset: const Offset(0, 8),
        ),
    ],
  );
}

class _QuickTile extends StatelessWidget {
  const _QuickTile({required this.item});
  final _QuickItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: item.semantics,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: _softPanel(scheme, glow: item.tint),
        child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            item.onTap();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: item.tint.withValues(alpha: 0.14), shape: BoxShape.circle),
                  child: Icon(item.icon, size: 22, color: item.tint),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
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

/// Minimal shortcut: no card, just icon + label. The press feedback is a soft
/// pill-shaped ripple clipped to a stadium, so there is never a square flash.
class _MinimalQuickTile extends StatelessWidget {
  const _MinimalQuickTile({required this.item});
  final _QuickItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const shape = StadiumBorder();
    return Semantics(
      button: true,
      label: item.semantics,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: shape,
          splashColor: scheme.primary.withValues(alpha: 0.10),
          highlightColor: scheme.primary.withValues(alpha: 0.06),
          hoverColor: scheme.onSurface.withValues(alpha: 0.04),
          focusColor: scheme.primary.withValues(alpha: 0.10),
          onTap: () {
            HapticFeedback.selectionClick();
            item.onTap();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 32,
                  child: Center(child: Icon(item.icon, size: 26, color: item.tint)),
                ),
                const SizedBox(height: 6),
                Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: scheme.onSurface.withValues(alpha: 0.86), letterSpacing: -0.1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentSection extends ConsumerWidget {
  const _RecentSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final items = ref.watch(downloadsControllerProvider).maybeWhen(
          data: (rows) => rows,
          orElse: () => const <DownloadRecord>[],
        );
    final recent = items.take(4).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Semantics(
              header: true,
              child: const Text('Recent', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => context.go('/downloads'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              child: const Text('View all'),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        if (recent.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: DecoratedBox(
              decoration: _softPanel(scheme),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Row(
                  children: [
                    Icon(Icons.movie_outlined, color: scheme.primary),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        'Nothing saved yet. Paste a public link above and it will show up here.',
                        style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          for (final r in recent) _RecentCard(record: r),
      ],
    );
  }
}

class _RecentCard extends ConsumerWidget {
  const _RecentCard({required this.record});
  final DownloadRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final fmt = ref.watch(formattersProvider);
    final size = record.fileSize != null ? fmt.bytes(record.fileSize) : '';
    final meta = [record.platform.displayName, ?record.quality, if (size.isNotEmpty) size].join(' - ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Semantics(
        button: true,
        label: 'Open ${record.title}',
        excludeSemantics: true,
        child: DecoratedBox(
          decoration: _softPanel(scheme),
          child: Material(
          color: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => context.push('/downloads/${record.id}'),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  SizedBox(
                    width: 72,
                    height: 72,
                    child: VideoThumbnail(
                      url: record.thumbnailUrl,
                      durationSeconds: record.durationSeconds,
                      height: 72,
                      borderRadius: 16,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          record.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, height: 1.25),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            PlatformLogo(platform: record.platform, size: 13),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                meta,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Play',
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    onPressed: () => openInAppPlayer(context, record),
                    icon: const Icon(Icons.play_arrow_rounded),
                  ),
                ],
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }
}
