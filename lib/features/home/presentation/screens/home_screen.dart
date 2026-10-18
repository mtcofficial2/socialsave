import 'package:social_save/web/web_relay.dart';
import 'package:social_save/core/config/build_flags.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:social_save/core/platform/plat.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:social_save/core/network/dio_client.dart';
import 'package:social_save/features/library/phone_handoff.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/platform/desktop_support.dart';
import 'package:social_save/core/storage/storage_migration.dart';
import 'package:social_save/core/storage/vault_recovery.dart';
import 'package:social_save/features/library/presentation/library_screen.dart'
    show vaultServiceProvider;
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/features/home/presentation/providers/home_controller.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/downloads/presentation/providers/downloads_controller.dart';
import 'package:social_save/features/home/presentation/widgets/recent_downloads_list.dart';
import 'package:social_save/shared/widgets/platform_logo.dart';
import 'package:social_save/features/home/presentation/widgets/supported_platforms.dart';
import 'package:social_save/features/home/presentation/widgets/save_queue_section.dart';
import 'package:social_save/features/home/presentation/widgets/url_input_card.dart';
import 'package:social_save/features/updates/update_card.dart';
import 'package:social_save/shared/widgets/brand_header.dart';
import 'package:social_save/shared/widgets/compliance_notice.dart';
import 'package:social_save/shared/widgets/page_layout.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  static bool _receiveHandled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Web: no files to migrate, and reading the clipboard on load would
      // pop a browser permission prompt. Paste reads it on a tap instead.
      if (Plat.isWeb) {
        // A QR / link from web nearby share: ?receive=CODE
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
    if (state == AppLifecycleState.resumed && !Plat.isWeb) {
      unawaited(_onArrive());
    }
  }

  Future<void> _onArrive() async {
    if (!mounted) return;
    if (await _consumeShare()) return;
    await _importClipboard();
  }

  Future<bool> _consumeShare() async {
    if (!mounted) return false;
    // Windows has no share intent; links come from paste / clipboard instead.
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
    await _openPreview(url);
    return true;
  }

  /// Opens Preview without the keyboard: the link field lost focus before,
  /// and getting it back on return popped the keyboard over Home (1.0.36).
  Future<void> _openPreview(Object extra) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await context.push('/preview', extra: extra);
    if (mounted && !Plat.isWindows) FocusManager.instance.primaryFocus?.unfocus();
  }

  Future<void> _importClipboard() async {
    if (!mounted) return;
    // Only when Home is on screen: never push a preview over the player or
    // another page (that stole the player's keyboard on PC).
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    // A copied link is offered by LinkOfferWatcher (quiet sheet), not auto-opened.
    if (mounted) {
      await ref.read(homeControllerProvider.notifier).refreshClipboardOffer();
    }
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

  /// Centered "Download this video?" check before a pasted link is analyzed.
  Future<bool> _confirmDownload(String url) async {
    final scheme = Theme.of(context).colorScheme;
    final yes = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        key: const ValueKey('confirm-download'),
        icon: Icon(Icons.download_rounded, color: scheme.primary),
        title: const Text('Download this video?'),
        content: Text(
          url,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        ),
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

  Future<void> _playlist() async {
    final url = ref.read(homeControllerProvider.notifier).validatedUrl();
    if (url == null || !mounted) return;
    HapticFeedback.lightImpact();
    await context.push('/playlist', extra: url);
  }

  @override
  Widget build(BuildContext context) {
    if (Plat.isWindows) {
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyV, control: true): () =>
              unawaited(_paste()),
        },
        child: Focus(autofocus: true, child: _scaffold(context)),
      );
    }
    return _scaffold(context);
  }

  Widget _scaffold(BuildContext context) {
    return Scaffold(
      body: SafeArea(bottom: false, 
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (!Plat.isWeb && constraints.maxWidth >= kDesktopSplitWidth) {
              return _desktopHome(context);
            }
            return _narrowHome(context);
          },
        ),
      ),
    );
  }

  Widget _narrowHome(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 24 + MediaQuery.paddingOf(context).bottom),
          children: [
            const BrandHeader(),
            _tagline(context),
            const SizedBox(height: 8),
            const UpdateCard(),
            UrlInputCard(onAnalyze: _analyze, onPaste: _paste),
            _wakingRow(scheme),
            const _RecentLinks(),
            _playlistButton(),
            const SaveQueueSection(),
            const SizedBox(height: 8),
            // 1.0.36: sharing sits above Recent Downloads.
            const NearbyShareBar(compact: true),
            const SizedBox(height: 12),
            const RecentDownloadsSection(),
            const SizedBox(height: 16),
            const SupportedPlatformsSection(),
            const SizedBox(height: 16),
            const ComplianceNotice(compact: true),
          ],
        ),
      ),
    );
  }

  Widget _desktopHome(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Save a video',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 4),
          _tagline(context),
          if (DesktopSupport.isWindows) ...[
            const SizedBox(height: 6),
            Text(
              'Ctrl+V pastes a link. Esc goes back.',
              style: TextStyle(
                fontSize: 12,
                height: 1.3,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 18),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 6,
                  child: ListView(
                    padding: const EdgeInsets.only(right: 8, bottom: 12),
                    children: [
                      const UpdateCard(),
                      UrlInputCard(onAnalyze: _analyze, onPaste: _paste),
                      _wakingRow(scheme),
                      const _RecentLinks(),
                      _playlistButton(),
                      const SaveQueueSection(),
                      const SizedBox(height: 16),
                      const ComplianceNotice(compact: true),
                    ],
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  flex: 5,
                  child: ListView(
                    padding: const EdgeInsets.only(bottom: 12),
                    children: const [
                      // 1.0.36: sharing sits above Recent Downloads.
                      NearbyShareBar(compact: true),
                      SizedBox(height: 16),
                      RecentDownloadsSection(),
                      SizedBox(height: 16),
                      SupportedPlatformsSection(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tagline(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      AppConstants.appTagline.endsWith('.')
          ? AppConstants.appTagline
          : '${AppConstants.appTagline}.',
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        color: scheme.onSurfaceVariant,
        fontSize: 14,
        height: 1.4,
      ),
    );
  }

  Widget _wakingRow(ColorScheme scheme) {
    return ValueListenableBuilder<bool>(
      valueListenable: DioClient.waking,
      builder: (context, waking, _) => !waking
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      kLocalEngine
                          ? 'Starting the download engine on this PC…'
                          : 'Waking the SocialSave server… this can take up to a minute.',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _playlistButton() {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: _playlist,
        icon: const Icon(Icons.playlist_play_rounded),
        label: const Text('Save a public playlist'),
      ),
    );
  }
}

/// Up to four links the user already saved. A tap fills the field and stays
/// on Home, so the link can be edited before Analyze.
class _RecentLinks extends ConsumerWidget {
  const _RecentLinks();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = ref
        .watch(downloadsControllerProvider)
        .maybeWhen(
          data: (rows) => rows,
          orElse: () => const <DownloadRecord>[],
        );
    final links = _uniqueRecentLinks(records);
    if (links.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Recent links',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: links.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final row = links[index];
                final url = row.sourceUrl.trim();
                return Tooltip(
                  message: url,
                  child: Material(
                    color: scheme.surfaceContainerLow,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(99),
                      side: BorderSide(color: scheme.outlineVariant),
                    ),
                    child: InkWell(
                      key: ValueKey('recent-link-$url'),
                      customBorder: const StadiumBorder(),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        ref.read(homeControllerProvider.notifier).setUrl(url);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            PlatformLogo(platform: row.platform, size: 14),
                            const SizedBox(width: 6),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 168),
                              child: Text(
                                _recentLinkLabel(row),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: scheme.onSurface,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

List<DownloadRecord> _uniqueRecentLinks(List<DownloadRecord> rows) {
  final seen = <String>{};
  final links = <DownloadRecord>[];
  for (final row in rows) {
    final url = row.sourceUrl.trim();
    if (url.isEmpty || !seen.add(url)) continue;
    links.add(row);
    if (links.length == 4) break;
  }
  return links;
}

String _recentLinkLabel(DownloadRecord row) {
  final title = row.title.trim();
  if (title.isNotEmpty && title.toLowerCase() != 'untitled video') return title;
  final host = Uri.tryParse(row.sourceUrl)?.host ?? row.sourceUrl;
  return host.startsWith('www.') ? host.substring(4) : host;
}
