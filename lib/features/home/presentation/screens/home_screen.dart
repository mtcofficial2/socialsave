import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/features/home/presentation/providers/home_controller.dart';
import 'package:social_save/features/home/presentation/widgets/recent_downloads_list.dart';
import 'package:social_save/features/home/presentation/widgets/supported_platforms.dart';
import 'package:social_save/features/home/presentation/widgets/url_input_card.dart';
import 'package:social_save/shared/widgets/app_logo.dart';
import 'package:social_save/shared/widgets/compliance_notice.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const AppLogo(showWordmark: true, size: 32),
        actions: [
          IconButton(
            tooltip: 'Settings',
            onPressed: () => context.go('/settings'),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            AppConstants.appTagline,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 16),
          UrlInputCard(
            onAnalyze: () async {
              final result =
                  await ref.read(homeControllerProvider.notifier).analyze();
              if (result != null && context.mounted) {
                await context.push('/preview', extra: result);
              }
            },
          ),
          const SizedBox(height: 16),
          const ComplianceNotice(compact: true),
          const SizedBox(height: 24),
          const SupportedPlatformsSection(),
          const SizedBox(height: 24),
          const RecentDownloadsSection(),
        ],
      ),
    );
  }
}
