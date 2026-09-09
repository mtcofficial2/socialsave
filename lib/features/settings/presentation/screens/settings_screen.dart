import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/config/env_config.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/storage/download_path_service.dart';
import 'package:social_save/features/downloads/presentation/providers/downloads_controller.dart';
import 'package:social_save/features/settings/domain/entities/app_settings.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionLabel('Appearance'),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto)),
              ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
            ],
            selected: {settings.themeMode},
            onSelectionChanged: (value) => controller.setThemeMode(value.first),
          ),
          const SizedBox(height: 8),
          const _SectionLabel('Downloads'),
          SwitchListTile(
            title: const Text('Wi-Fi only'),
            subtitle: const Text('Avoid cellular data for downloads'),
            value: settings.wifiOnly,
            onChanged: controller.setWifiOnly,
          ),
          SwitchListTile(
            title: const Text('Auto-start downloads'),
            subtitle: const Text('Begin saving as soon as a format is confirmed'),
            value: settings.autoStartDownloads,
            onChanged: controller.setAutoStart,
          ),
          SwitchListTile(
            title: const Text('Notifications'),
            subtitle: const Text('Notify when a download finishes or fails'),
            value: settings.notificationsEnabled,
            onChanged: (value) async {
              if (value) {
                await ref.read(notificationServiceProvider).requestPermission();
              }
              await controller.setNotifications(value);
            },
          ),
          ListTile(
            title: const Text('Download location'),
            subtitle: Text(
              settings.downloadLocation == DownloadLocation.publicDownloads
                  ? 'Public Downloads folder'
                  : 'App storage (recommended)',
            ),
            trailing: const Icon(Icons.folder_outlined),
            onTap: () => _pickLocation(context, controller, settings),
          ),
          ListTile(
            title: const Text('Default quality'),
            subtitle: Text(settings.defaultQuality.label),
            onTap: () => _pickQuality(context, controller, settings),
          ),
          ListTile(
            title: const Text('Default format'),
            subtitle: Text(settings.defaultFormat.label),
            onTap: () => _pickFormat(context, controller, settings),
          ),
          const _SectionLabel('Storage'),
          ListTile(
            title: const Text('Clear history'),
            subtitle: const Text('Remove download records, keep files'),
            onTap: () async {
              await ref
                  .read(downloadsControllerProvider.notifier)
                  .clear(deleteFiles: false);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('History cleared')),
                );
              }
            },
          ),
          ListTile(
            title: const Text('Clear cache'),
            subtitle: const Text('Thumbnails and temporary files'),
            onTap: () async {
              await ref.read(downloadPathServiceProvider).clearCache();
              await ref.read(thumbnailCacheManagerProvider).emptyCache();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Cache cleared')),
                );
              }
            },
          ),
          const _SectionLabel('Legal'),
          ListTile(
            title: const Text('Privacy policy'),
            onTap: () => context.push('/legal/privacy'),
          ),
          ListTile(
            title: const Text('Terms of service'),
            onTap: () => context.push('/legal/terms'),
          ),
          ListTile(
            title: const Text('About'),
            subtitle: Text('${AppConstants.appName} ${AppConstants.appVersion}'),
            onTap: () => context.push('/about'),
          ),
          const _SectionLabel('Developer'),
          ListTile(
            title: const Text('API base URL'),
            subtitle: Text(EnvConfig.apiBaseUrl),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 32),
            child: Text(
              'Provider API credentials stay on the server. The Flutter app only talks to your backend.',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickLocation(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final value = await showModalBottomSheet<DownloadLocation>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('App storage'),
              subtitle: const Text('No extra permission required'),
              selected: settings.downloadLocation == DownloadLocation.appStorage,
              onTap: () => Navigator.pop(context, DownloadLocation.appStorage),
            ),
            ListTile(
              title: const Text('Public Downloads'),
              subtitle: const Text('May require storage permission'),
              selected:
                  settings.downloadLocation == DownloadLocation.publicDownloads,
              onTap: () =>
                  Navigator.pop(context, DownloadLocation.publicDownloads),
            ),
          ],
        ),
      ),
    );
    if (value != null) {
      await controller.setDownloadLocation(value);
    }
  }

  Future<void> _pickQuality(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final value = await showModalBottomSheet<VideoQualityPreference>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: VideoQualityPreference.values
              .map(
                (item) => ListTile(
                  title: Text(item.label),
                  selected: settings.defaultQuality == item,
                  onTap: () => Navigator.pop(context, item),
                ),
              )
              .toList(),
        ),
      ),
    );
    if (value != null) {
      await controller.setDefaultQuality(value);
    }
  }

  Future<void> _pickFormat(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    final value = await showModalBottomSheet<VideoFormatPreference>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: VideoFormatPreference.values
              .map(
                (item) => ListTile(
                  title: Text(item.label),
                  selected: settings.defaultFormat == item,
                  onTap: () => Navigator.pop(context, item),
                ),
              )
              .toList(),
        ),
      ),
    );
    if (value != null) {
      await controller.setDefaultFormat(value);
    }
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}
