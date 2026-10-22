import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/network/dio_client.dart';
import 'package:social_save/core/platform/desktop_support.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/core/storage/storage_migration.dart';
import 'package:social_save/core/storage/vault_recovery.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/downloads/presentation/providers/downloads_controller.dart';
import 'package:social_save/features/home/presentation/providers/home_controller.dart';
import 'package:social_save/features/home/presentation/screens/home_screen.dart';
import 'package:social_save/features/home/presentation/widgets/save_queue_section.dart';
import 'package:social_save/features/home/presentation/widgets/supported_platforms.dart';
import 'package:social_save/features/home/presentation/widgets/url_input_card.dart';
import 'package:social_save/features/home/presentation/widgets/link_offer.dart';
import 'package:social_save/features/library/hotspot_share.dart';
import 'package:social_save/features/library/phone_handoff.dart';
import 'package:social_save/features/library/presentation/library_screen.dart'
    show vaultServiceProvider;
import 'package:social_save/features/player/open_player.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';
import 'package:social_save/features/status/hd_status_screen.dart';
import 'package:social_save/features/updates/update_card.dart';
import 'package:social_save/shared/widgets/compliance_notice.dart';
import 'package:social_save/shared/widgets/liquid_glass.dart';
import 'package:social_save/shared/widgets/page_layout.dart';
import 'package:social_save/shared/widgets/platform_logo.dart';
import 'package:social_save/shared/widgets/video_thumbnail.dart';
import 'package:social_save/web/web_relay.dart';

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
    if (await _consumeShare()) return;
    await _importClipboard();
  }

  Future<bool> _consumeShare() async {
    if (!mounted) return false;
    if (DesktopSupport.isWindows) return false;
    const channel = MethodChannel('socialsave/media');
    String? text;
    try {
      text = await channel.invokeMethod<String>('consumeSharedText');
    } catch (_) {
      return false;
    }
    if (text == null || text.trim().isEmpty || !mounted) return false;
    ref.read(homeControllerProvider.notifier).setUrl(text);
    final url = ref.read(homeControllerProvider.notifier).validatedUrl();
    if (url == null || !mounted) return false;
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

  Future<void> _paste() async {
    await ref.read(homeControllerProvider.notifier).pasteFromClipboard();
    if (!mounted) return;
    final state = ref.read(homeControllerProvider);
    if (state.error != null || state.url.isEmpty) return;
    HapticFeedback.lightImpact();
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
    final url = ref.read(homeControllerProvider.notifier).validatedUrl();
    if (url == null || !mounted) return;
    HapticFeedback.lightImpact();
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

  Widget _header(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tag = AppConstants.appTagline.endsWith('.') ? AppConstants.appTagline : '${AppConstants.appTagline}.';
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [scheme.primary, scheme.tertiary]),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'SocialSave',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Semantics(
            header: true,
            child: Text(
              'Save a video',
              style: Theme.of(context).textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1, height: 1.1),
            ),
          ),
          const SizedBox(height: 8),
          Text(tag, style: TextStyle(fontSize: 15, height: 1.45, color: scheme.onSurfaceVariant)),
          if (DesktopSupport.isWindows)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Ctrl+V pastes a link.', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }

  List<Widget> _primary(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return [
      _Reveal(index: 1, child: UrlInputCard(onAnalyze: _analyze, onPaste: _paste)),
      _wakingRow(scheme),
      const SizedBox(height: 14),
      _Reveal(index: 2, child: _SendReceiveCard(onTap: () => context.push('/share'))),
      const SizedBox(height: 14),
      _Reveal(index: 3, child: const HdStatusEntry()),
      const SizedBox(height: 14),
      _Reveal(index: 4, child: _QuickActions(onLibrary: () => context.go('/library'))),
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
            _Reveal(index: 0, child: _header(context)),
            const UpdateCard(),
            ..._primary(context),
            const SaveQueueSection(),
            const SizedBox(height: 28),
            _Reveal(index: 4, child: const _RecentSection()),
            const SizedBox(height: 28),
            const SupportedPlatformsSection(),
            const SizedBox(height: 16),
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
                _Reveal(index: 0, child: _header(context)),
                const UpdateCard(),
                ..._primary(context),
                const SaveQueueSection(),
                const SizedBox(height: 24),
                const ComplianceNotice(compact: true),
              ],
            ),
          ),
          const SizedBox(width: 32),
          Expanded(
            flex: 5,
            child: ListView(
              padding: const EdgeInsets.only(top: 28, bottom: 16),
              children: [
                _Reveal(index: 4, child: const _RecentSection()),
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
                      'Getting the download engine ready. This can take a moment.',
                      style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

/// Fade + slide-up entrance, staggered by [index].
class _Reveal extends StatefulWidget {
  const _Reveal({required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer(Duration(milliseconds: 60 * widget.index), () {
      if (mounted) unawaited(_c.forward());
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero).animate(curve),
        child: widget.child,
      ),
    );
  }
}

/// The one prominent entry for nearby sharing.
class _SendReceiveCard extends StatelessWidget {
  const _SendReceiveCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (LiquidGlassScope.of(context)) {
      final dark = scheme.brightness == Brightness.dark;
      return GlassPress(
        key: const ValueKey('home-send-receive'),
        semanticLabel: 'Send or receive files with a nearby phone or PC',
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: IosGlassPlate(
          dark: dark,
          radius: 28,
          shadow: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.16),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.swap_horiz_rounded, size: 28, color: scheme.primary),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Send / Receive',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3, color: scheme.onSurface),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Share files with a phone or PC nearby',
                        style: TextStyle(fontSize: 13, height: 1.3, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_rounded, color: scheme.primary),
              ],
            ),
          ),
        ),
      );
    }
    return Semantics(
      button: true,
      label: 'Send or receive files with a nearby phone or PC',
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(28),
        child: InkWell(
          key: const ValueKey('home-send-receive'),
          borderRadius: BorderRadius.circular(28),
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [scheme.primaryContainer, Color.lerp(scheme.primaryContainer, scheme.tertiaryContainer, 0.75)!],
              ),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.25)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.18), shape: BoxShape.circle),
                  child: Icon(Icons.swap_horiz_rounded, size: 28, color: scheme.onPrimaryContainer),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Send / Receive',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3, color: scheme.onPrimaryContainer),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Share files with a phone or PC nearby',
                        style: TextStyle(fontSize: 13, height: 1.3, color: scheme.onPrimaryContainer.withValues(alpha: 0.75)),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_rounded, color: scheme.onPrimaryContainer),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickActions extends ConsumerWidget {
  const _QuickActions({required this.onLibrary});
  final VoidCallback onLibrary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final minimal = ref.watch(settingsControllerProvider.select((s) => s.minimalShortcuts));
    final scan = HotspotShare.supported ? 'Scan QR' : 'Receive';
    final items = <_QuickItem>[
      if (HotspotShare.hostSupported)
        _QuickItem(Icons.wifi_tethering_rounded, 'Hotspot', 'Hotspot share', () => showHotspotQuickShare(context)),
      _QuickItem(Icons.public_rounded, 'Browse', 'Browse sites and download videos', () => context.push('/browse')),
      _QuickItem(Icons.library_music_rounded, 'Music', 'Open music player', () => context.push('/music')),
      _QuickItem(Icons.video_library_rounded, 'Library', 'Open library', onLibrary),
      _QuickItem(Icons.qr_code_scanner_rounded, scan, 'Scan a QR code to join', () async {
        await showReceiveFromPhone(context);
      }),
    ];
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: Row(
        key: ValueKey(minimal),
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) SizedBox(width: minimal ? 4 : 10),
            Expanded(child: minimal ? _MinimalQuickTile(item: items[i]) : _QuickTile(item: items[i])),
          ],
        ],
      ),
    );
  }
}

class _QuickItem {
  const _QuickItem(this.icon, this.label, this.semantics, this.onTap);
  final IconData icon;
  final String label;
  final String semantics;
  final VoidCallback onTap;
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
      child: Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
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
                  decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.12), shape: BoxShape.circle),
                  child: Icon(item.icon, size: 22, color: scheme.primary),
                ),
                const SizedBox(height: 8),
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
                  child: Center(child: Icon(item.icon, size: 26, color: scheme.primary)),
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
        const SizedBox(height: 4),
        if (recent.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Nothing saved yet. Paste a public link above to start.',
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
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
        child: Material(
          color: scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
          ),
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
    );
  }
}
