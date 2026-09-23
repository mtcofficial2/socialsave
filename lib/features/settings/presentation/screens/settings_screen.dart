import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/storage/download_path_service.dart';
import 'package:social_save/core/theme/app_colors.dart';
import 'package:social_save/core/theme/app_fonts.dart';
import 'package:social_save/features/settings/domain/entities/app_settings.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';
import 'package:social_save/features/settings/presentation/screens/font_picker_sheet.dart';
import 'package:social_save/shared/widgets/brand_header.dart';
import 'package:social_save/shared/widgets/glass.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            const BrandHeader(),
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: scheme.surfaceContainerLow,
                  child: IconButton(
                    onPressed: () => context.go('/'),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Settings',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        'Archival preferences & fair-use compliance',
                        style: TextStyle(fontSize: 11, color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
                CircleAvatar(
                  backgroundColor: scheme.primary.withValues(alpha: 0.08),
                  child: Icon(Icons.verified_user, color: scheme.primary, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _groupTitle(context, Icons.palette_outlined, 'Appearance & Theme'),
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Text('Interface Theme', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                        const Spacer(),
                        Text(
                          settings.themeMode.name[0].toUpperCase() + settings.themeMode.name.substring(1),
                          style: TextStyle(color: scheme.primary, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          _themeCell(context, 'System', Icons.devices, ThemeMode.system, settings.themeMode, controller.setThemeMode),
                          _themeCell(context, 'Light', Icons.light_mode, ThemeMode.light, settings.themeMode, controller.setThemeMode),
                          _themeCell(context, 'Dark', Icons.dark_mode_outlined, ThemeMode.dark, settings.themeMode, controller.setThemeMode),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _navRow(
                      context,
                      icon: Icons.font_download_outlined,
                      title: 'App typeface',
                      subtitle: AppFonts.byId(settings.fontFamily).mood,
                      trailing: AppFonts.byId(settings.fontFamily).label,
                      onTap: () async {
                        final chosen = await FontPickerSheet.open(
                          context,
                          selectedId: settings.fontFamily,
                        );
                        if (chosen != null) {
                          await controller.setFontFamily(chosen);
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: scheme.primary,
                          child: const Icon(Icons.check, color: Colors.white, size: 16),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Accent Color', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                              Text('Archival Teal (#0F766E)', style: TextStyle(fontSize: 12, color: AppColors.muted)),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainer,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: const Text('Default', style: TextStyle(fontSize: 11)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            _groupTitle(context, Icons.download_for_offline_outlined, 'Download Preferences'),
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _toggleRow(
                      context,
                      icon: Icons.wifi,
                      title: 'Download over Wi-Fi only',
                      subtitle: 'Conserve mobile cellular bandwidth',
                      value: settings.wifiOnly,
                      onChanged: controller.setWifiOnly,
                    ),
                    const SizedBox(height: 16),
                    _toggleRow(
                      context,
                      icon: Icons.photo_library_outlined,
                      title: 'Save to device Downloads',
                      subtitle: 'Put files in Downloads/SocialSave for all players',
                      value: settings.downloadLocation == DownloadLocation.publicDownloads,
                      onChanged: (on) => controller.setDownloadLocation(
                        on ? DownloadLocation.publicDownloads : DownloadLocation.appStorage,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _navRow(
                      context,
                      icon: Icons.high_quality_outlined,
                      title: 'Default Resolution',
                      subtitle: 'Best Quality (${settings.defaultQuality.label})',
                      trailing: settings.defaultQuality.label,
                      onTap: () => _pickQuality(context, controller, settings),
                    ),
                    const SizedBox(height: 8),
                    _navRow(
                      context,
                      icon: Icons.folder_special_outlined,
                      title: 'Download Location',
                      subtitle: settings.downloadLocation == DownloadLocation.publicDownloads
                          ? 'Downloads/SocialSave'
                          : 'App private storage',
                      onTap: () => _pickLocation(context, controller, settings),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            _groupTitle(context, Icons.play_circle_outline, 'Player'),
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _toggleRow(
                  context,
                  icon: Icons.skip_next_rounded,
                  title: 'Play next in Library',
                  subtitle:
                      'When a video ends, count down 5 seconds to the next one. Tap Rewatch to play it again.',
                  value: settings.autoPlayNextInGallery,
                  onChanged: controller.setAutoPlayNextInGallery,
                ),
              ),
            ),
            const SizedBox(height: 20),
            _groupTitle(context, Icons.notifications_active_outlined, 'Notifications & System'),
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _toggleRow(
                      context,
                      icon: Icons.done_all,
                      title: 'Download Complete Alerts',
                      subtitle: 'Haptic chime when video parsing succeeds',
                      value: settings.notificationsEnabled,
                      onChanged: (value) async {
                        if (value) {
                          await ref.read(notificationServiceProvider).requestPermission();
                        }
                        await controller.setNotifications(value);
                      },
                    ),
                    const SizedBox(height: 16),
                    _toggleRow(
                      context,
                      icon: Icons.preview_outlined,
                      title: 'Thumbnail in Notification',
                      subtitle: 'Display creator thumbnail on lockscreen preview',
                      value: settings.notificationsEnabled,
                      onChanged: controller.setNotifications,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            _groupTitle(context, Icons.gavel, 'Legal, Compliance & Privacy'),
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: scheme.secondaryContainer.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.policy_outlined, color: scheme.secondary),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Expanded(
                                      child: Text(
                                        'Archival Fair-Use Policy',
                                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: scheme.primary.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(999),
                                      ),
                                      child: Text(
                                        '17 U.S.C. § 107',
                                        style: TextStyle(
                                          color: scheme.primary,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'SocialSave adheres strictly to digital fair-use standards and recognizes creators\' statutory rights. Downloaded media is intended strictly for personal, offline archival curation and educational preservation.',
                                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, height: 1.4),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.description_outlined),
                      title: const Text('Terms of Service & Copyright Policy'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.push('/legal/terms'),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.cleaning_services_outlined, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 16),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Temporary Video Cache',
                                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Thumbnails and temporary files',
                                style: TextStyle(fontSize: 13, color: AppColors.muted),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(72, 36),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () async {
                            await ref.read(downloadPathServiceProvider).clearCache();
                            await ref.read(thumbnailCacheManagerProvider).emptyCache();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Cache cleared')),
                              );
                            }
                          },
                          child: const Text('Clear'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.verified, size: 16, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      'SocialSave Archiver',
                      style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w800, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'SocialSave v${AppConstants.appVersion} • Compliant Video Archiver',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
                Text(
                  'Encrypted local sandboxing • Zero cloud logging',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupTitle(BuildContext context, IconData icon, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _themeCell(
    BuildContext context,
    String label,
    IconData icon,
    ThemeMode mode,
    ThemeMode current,
    ValueChanged<ThemeMode> onChanged,
  ) {
    final selected = current == mode;
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Material(
        color: selected ? scheme.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: () => onChanged(mode),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 16, color: selected ? Colors.white : scheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _toggleRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: scheme.primary, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              Text(subtitle, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }

  Widget _navRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    String? trailing,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: scheme.primary, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  Text(subtitle, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            if (trailing != null)
              Text(trailing, style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700, fontSize: 12)),
            Icon(Icons.unfold_more, size: 18, color: scheme.primary),
          ],
        ),
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
              selected: settings.downloadLocation == DownloadLocation.appStorage,
              onTap: () => Navigator.pop(context, DownloadLocation.appStorage),
            ),
            ListTile(
              title: const Text('Public Downloads'),
              selected: settings.downloadLocation == DownloadLocation.publicDownloads,
              onTap: () => Navigator.pop(context, DownloadLocation.publicDownloads),
            ),
          ],
        ),
      ),
    );
    if (value != null) await controller.setDownloadLocation(value);
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
    if (value != null) await controller.setDefaultQuality(value);
  }
}
