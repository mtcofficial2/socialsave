import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/features/home/presentation/providers/home_controller.dart';
import 'package:social_save/features/home/presentation/widgets/recent_downloads_list.dart';
import 'package:social_save/features/home/presentation/widgets/supported_platforms.dart';
import 'package:social_save/features/home/presentation/widgets/save_queue_section.dart';
import 'package:social_save/features/home/presentation/widgets/url_input_card.dart';
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
    const channel = MethodChannel('socialsave/media');
    final text = await channel.invokeMethod<String>('consumeSharedText');
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
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
            UrlInputCard(onAnalyze: _analyze, onPaste: _paste),
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
    );
  }
}
