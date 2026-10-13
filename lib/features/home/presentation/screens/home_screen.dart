import 'dart:io';
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
import 'package:social_save/features/library/presentation/library_screen.dart' show vaultServiceProvider;
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/features/home/presentation/providers/home_controller.dart';
import 'package:social_save/features/home/presentation/widgets/recent_downloads_list.dart';
import 'package:social_save/features/home/presentation/widgets/supported_platforms.dart';
import 'package:social_save/features/home/presentation/widgets/save_queue_section.dart';
import 'package:social_save/features/home/presentation/widgets/url_input_card.dart';
import 'package:social_save/features/updates/update_card.dart';
import 'package:social_save/shared/widgets/brand_header.dart';
import 'package:social_save/shared/widgets/compliance_notice.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
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
    if (state == AppLifecycleState.resumed) {
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
    await context.push('/preview', extra: url);
    return true;
  }

  Future<void> _importClipboard() async {
    if (!mounted) return;
    // Only when Home is on screen: never push a preview over the player or
    // another page (that stole the player's keyboard on PC).
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
    final result = await ref
        .read(homeControllerProvider.notifier)
        .importClipboardAndAnalyze(auto: true);
    if (result != null && mounted) {
      HapticFeedback.lightImpact();
      await context.push('/preview', extra: result);
      return;
    }
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
    await context.push('/preview', extra: state.url);
  }

  Future<void> _analyze() async {
    final url = ref.read(homeControllerProvider.notifier).validatedUrl();
    if (url == null || !mounted) return;
    HapticFeedback.lightImpact();
    await context.push('/preview', extra: url);
  }

  Future<void> _playlist() async {
    final url = ref.read(homeControllerProvider.notifier).validatedUrl();
    if (url == null || !mounted) return;
    HapticFeedback.lightImpact();
    await context.push('/playlist', extra: url);
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) {
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyV, control: true): () => unawaited(_paste()),
        },
        child: Focus(autofocus: true, child: _scaffold(context)),
      );
    }
    return _scaffold(context);
  }

  Widget _scaffold(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            const BrandHeader(),
            Text(
              AppConstants.appTagline.endsWith('.')
                  ? AppConstants.appTagline
                  : '${AppConstants.appTagline}.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontSize: 14,
                    height: 1.4,
                  ),
            ),
            const SizedBox(height: 16),
            const UpdateCard(),
            UrlInputCard(onAnalyze: _analyze, onPaste: _paste),
            ValueListenableBuilder<bool>(
              valueListenable: DioClient.waking,
              builder: (context, waking, _) => !waking
                  ? const SizedBox.shrink()
                  : const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 10),
                          Expanded(child: Text('Waking the SocialSave server… this can take up to a minute.')),
                        ],
                      ),
                    ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _playlist,
                icon: const Icon(Icons.playlist_play_rounded),
                label: const Text('Save a public playlist'),
              ),
            ),
            const SizedBox(height: 8),
            const NearbyShareBar(compact: true),
            const SizedBox(height: 12),
            const SaveQueueSection(),
            const SizedBox(height: 16),
            const ComplianceNotice(compact: true),
            const SizedBox(height: 20),
            const SupportedPlatformsSection(),
            const SizedBox(height: 20),
            const RecentDownloadsSection(),
          ],
        ),
        ),
        ),
      ),
    );
  }
}
