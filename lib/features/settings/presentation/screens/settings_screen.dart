import 'dart:convert';
import 'package:social_save/core/config/build_flags.dart';
import 'package:social_save/core/platform/plat.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:social_save/shared/widgets/desktop_columns.dart';
import 'package:social_save/shared/widgets/page_layout.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/platform/desktop_support.dart';
import 'package:social_save/core/platform/media_events.dart';
import 'package:social_save/core/platform/phone_body.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/library/hotspot_share.dart';
import 'package:social_save/features/library/index_backup.dart';
import 'package:social_save/features/library/library_catalog.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/storage/download_path_service.dart';
import 'package:social_save/core/theme/app_fonts.dart';
import 'package:social_save/features/settings/domain/entities/app_settings.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';
import 'package:social_save/features/settings/presentation/screens/font_picker_sheet.dart';
import 'package:social_save/shared/widgets/glass.dart';
import 'package:social_save/features/library/share_hub.dart';
import 'package:social_save/features/settings/presentation/widgets/engine_section.dart';
import 'package:social_save/features/settings/presentation/widgets/phone_engine_section.dart';
import 'package:social_save/features/settings/presentation/widgets/storage_section.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(bottom: false, 
        child: ListView(
          padding: pagePadding(context, top: 12, bottom: 32 + MediaQuery.paddingOf(context).bottom),
          children: [
            Text('Settings', style: pageTitleStyle(context)),
            const SizedBox(height: 4),
            Text(
              'Downloads, playback, and how this device behaves.',
              style: TextStyle(fontSize: 13, height: 1.35, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            const _SettingsSearch(),
            if (!kIsWeb)
              ListTile(
                key: const ValueKey('settings-trusted'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.verified_user_rounded),
                title: const Text('Trusted devices'),
                subtitle: const Text('See and revoke devices that can send without asking'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TrustedDevicesScreen())),
              ),
            const SizedBox(height: 12),
            DesktopColumns(
              sections: [
                _Sec(title: 'Appearance & Theme', keys: 'appearance theme dark light font typeface wallpaper color', child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
            _groupTitle(context, Icons.palette_outlined, 'Appearance & Theme'),
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Interface Theme', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
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
                    // Web: browsers give no wallpaper palette.
                    if (!kIsWeb) const SizedBox(height: 8),
                    if (!kIsWeb) Row(
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: scheme.primary,
                          child: const Icon(Icons.check, color: Colors.white, size: 16),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Wallpaper colors', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                              Text(
                                DesktopSupport.isWindows
                                    ? 'Uses the accent color from Windows'
                                    : 'Material You when the phone provides a palette',
                                style: TextStyle(fontSize: 13, height: 1.3, color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: settings.useDynamicColor,
                          onChanged: controller.setUseDynamicColor,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SwitchListTile(
                      key: const ValueKey('classic-home-switch'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Classic home screen', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      subtitle: Text('Turn on to bring back the previous Home layout', style: TextStyle(fontSize: 13, height: 1.3, color: scheme.onSurfaceVariant)),
                      value: settings.classicHome,
                      onChanged: controller.setClassicHome,
                    ),
                    SwitchListTile(
                      key: const ValueKey('classic-library-switch'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Classic library', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      subtitle: Text('Turn on to bring back the previous Library layout', style: TextStyle(fontSize: 13, height: 1.3, color: scheme.onSurfaceVariant)),
                      value: settings.classicLibrary,
                      onChanged: controller.setClassicLibrary,
                    ),
                    SwitchListTile(
                      key: const ValueKey('offer-copied-links-switch'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Offer to download copied links', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      subtitle: Text(Plat.isAndroid ? 'Ask when you copy a video link and open SocialSave' : 'Ask when you copy a video link, even from the tray', style: TextStyle(fontSize: 13, height: 1.3, color: scheme.onSurfaceVariant)),
                      value: settings.offerCopiedLinks,
                      onChanged: controller.setOfferCopiedLinks,
                    ),
                    if (Plat.isAndroid)
                      ListTile(
                        key: const ValueKey('background-detect-tile'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Detect links in the background', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                        subtitle: Text('Offer to download a copied link even when SocialSave is closed', style: TextStyle(fontSize: 13, height: 1.3, color: scheme.onSurfaceVariant)),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => context.push('/background-detect'),
                      ),
                  ],
                ),
              ),
            ),
                  ],
                )),
                _Sec(title: 'Download Preferences', keys: 'download wifi location quality resolution', child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
            _groupTitle(context, Icons.download_for_offline_outlined, 'Download Preferences'),
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    // Web: the browser picks where files go and cannot tell
                    // Wi-Fi from mobile data, so these rows are app-only.
                    if (!kIsWeb) ...[
                    _toggleRow(
                      context,
                      icon: Icons.wifi,
                      title: 'Download over Wi-Fi only',
                      subtitle: DesktopSupport.isWindows
                          ? 'Skip saves while this computer is on a metered connection'
                          : 'Conserve mobile cellular bandwidth',
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
                    ],
                    _navRow(
                      context,
                      icon: Icons.high_quality_outlined,
                      title: 'Default Resolution',
                      subtitle: 'Best Quality (${settings.defaultQuality.label})',
                      trailing: settings.defaultQuality.label,
                      onTap: () => _pickQuality(context, controller, settings),
                    ),
                    if (!kIsWeb) const SizedBox(height: 8),
                    if (!kIsWeb) _navRow(
                      context,
                      icon: Icons.folder_special_outlined,
                      title: 'Download Location',
                      subtitle: Plat.isWindows
                          ? r'Documents\SocialSave'
                          : settings.downloadLocation == DownloadLocation.publicDownloads
                          ? 'Downloads/SocialSave'
                          : 'App private storage',
                      onTap: () => _pickLocation(context, controller, settings),
                    ),
                  ],
                ),
              ),
            ),
                  ],
                )),
                _Sec(title: 'Player', keys: 'player play next library', child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
            _groupTitle(context, Icons.play_circle_outline, 'Player'),
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _toggleRow(
                  context,
                  icon: Icons.skip_next_rounded,
                  title: 'Play next in Library',
                  subtitle:
                      DesktopSupport.isWindows
                          ? 'When a video ends, count down 5 seconds to the next one. Click Rewatch to play it again.'
                          : 'When a video ends, count down 5 seconds to the next one. Tap Rewatch to play it again.',
                  value: settings.autoPlayNextInGallery,
                  onChanged: controller.setAutoPlayNextInGallery,
                ),
              ),
            ),
                  ],
                )),
                if (!DesktopSupport.isWindows && !kIsWeb)
                  _Sec(title: 'Phone', keys: 'phone battery charging pocket headset earphone volume vibrate save folder background play', child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
            _groupTitle(context, Icons.phone_android_rounded, 'Phone'),
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _toggleRow(
                      context,
                      icon: Icons.battery_charging_full_rounded,
                      title: 'Only while charging',
                      subtitle: 'Saves wait until the phone is plugged in',
                      value: settings.onlyWhileCharging,
                      onChanged: controller.setOnlyWhileCharging,
                    ),
                    const SizedBox(height: 16),
                    _toggleRow(
                      context,
                      icon: Icons.battery_alert_rounded,
                      title: 'Pause under 15% battery',
                      subtitle: 'A save on a charger keeps going',
                      value: settings.pauseBelowBattery,
                      onChanged: controller.setPauseBelowBattery,
                    ),
                    const SizedBox(height: 16),
                    _toggleRow(
                      context,
                      icon: Icons.stay_current_portrait_rounded,
                      title: 'Pause in a pocket',
                      subtitle: 'Face down or covered pauses playback and the current save',
                      value: settings.pocketPause,
                      onChanged: controller.setPocketPause,
                    ),
                    const SizedBox(height: 16),
                    if (Plat.isAndroid) ...[
                      _toggleRow(
                        context,
                        icon: Icons.screen_lock_portrait_rounded,
                        title: 'Keep playing when screen is off',
                        subtitle: 'Sound keeps going with the screen locked or the app in the background, with controls on the lock screen',
                        value: settings.backgroundPlay,
                        onChanged: controller.setBackgroundPlay,
                      ),
                      const SizedBox(height: 16),
                    ],
                    _toggleRow(
                      context,
                      icon: Icons.headphones_rounded,
                      title: 'Earphone button',
                      subtitle: 'One press plays or pauses. Two presses play the next video.',
                      value: settings.headsetControls,
                      onChanged: controller.setHeadsetControls,
                    ),
                    const SizedBox(height: 16),
                    _toggleRow(
                      context,
                      icon: Icons.volume_up_rounded,
                      title: 'Volume keys seek',
                      subtitle: 'While the screen is off, volume keys move 10 seconds',
                      value: settings.volumeKeysSeek,
                      onChanged: controller.setVolumeKeysSeek,
                    ),
                    const SizedBox(height: 16),
                    _toggleRow(
                      context,
                      icon: Icons.vibration_rounded,
                      title: 'Vibrate when a save finishes',
                      subtitle: 'One pulse when saved, two pulses when it fails',
                      value: settings.hapticAlerts,
                      onChanged: controller.setHapticAlerts,
                    ),
                    const SizedBox(height: 12),
                    _navRow(
                      context,
                      icon: Icons.folder_open_rounded,
                      title: 'Save folder',
                      subtitle: settings.saveTreeUri == null
                          ? 'Phone storage, SD card, or USB'
                          : 'Finished videos are also copied into the folder you chose',
                      trailing: settings.saveTreeUri == null ? 'Choose' : 'Change',
                      onTap: () => _pickSaveFolder(context, controller, settings),
                    ),
                  ],
                ),
              ),
            ),
                    ],
                  )),
                if (!kIsWeb)
                _Sec(title: 'Library & engine', keys: 'engine library backup restore index computer', child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
            if (!kLocalEngine && Plat.isAndroid)
              PhoneEngineSection(
                title: _groupTitle(context, Icons.memory_rounded, 'Download engine'),
              ),
            if (kLocalEngine)
              EngineSection(
                title: _groupTitle(context, Icons.memory_rounded, 'Download engine'),
              ),
            _groupTitle(
              context,
              Icons.devices_outlined,
              DesktopSupport.isWindows
                  ? 'Library on this computer'
                  : 'Library on this phone and a computer',
            ),
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    // The titles code is read on the website, so the
                    // desktop build (no hosted API) leaves it out.
                    if (!kLocalEngine) ...[
                    _navRow(
                      context,
                      icon: Icons.qr_code_rounded,
                      title: DesktopSupport.isWindows
                          ? 'Show titles on the website'
                          : 'Show titles on a computer',
                      subtitle: DesktopSupport.isWindows
                          ? 'A short code lists saved titles. Videos stay on this computer.'
                          : 'A short code lists saved titles. Videos stay on this phone.',
                      onTap: () => _pairLibrary(context, ref),
                    ),
                    const SizedBox(height: 8),
                    ],
                    _navRow(
                      context,
                      icon: Icons.lock_outline,
                      title: 'Back up library index',
                      subtitle: 'Encrypted titles and notes. Video files are not copied.',
                      onTap: () => _exportIndex(context, ref),
                    ),
                    const SizedBox(height: 8),
                    _navRow(
                      context,
                      icon: Icons.restore_rounded,
                      title: 'Restore library index',
                      subtitle: 'Open an encrypted SocialSave backup',
                      onTap: () => _importIndex(context, ref),
                    ),
                  ],
                ),
              ),
            ),
                  ],
                )),
                if (!kIsWeb)
                _Sec(title: 'Notifications & System', keys: 'notifications alerts thumbnail system', child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
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
                      subtitle: DesktopSupport.isWindows
                          ? 'A notice when a save finishes'
                          : 'Haptic chime when video parsing succeeds',
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
                      subtitle: DesktopSupport.isWindows
                          ? 'Show the video picture on the notice'
                          : 'Display creator thumbnail on lockscreen preview',
                      value: settings.notificationsEnabled,
                      onChanged: controller.setNotifications,
                    ),
                  ],
                ),
              ),
            ),
                  ],
                )),
                _Sec(title: 'Legal, Compliance & Privacy', keys: 'legal privacy terms policy compliance', child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
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
                    if (!kIsWeb && (Plat.isAndroid || Plat.isWindows)) const HotspotBandTile(),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.description_outlined),
                      title: const Text('Terms of Service & Copyright Policy'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.push('/legal/terms'),
                    ),
                    const SizedBox(height: 4),
                    // 1.0.37: real usage numbers; Clear only touches SocialSave's files.
                    if (!kIsWeb) const StorageSection(),
                  ],
                ),
              ),
            ),
                  ],
                )),
              ],
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
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
                Text(
                  'Encrypted local sandboxing • Zero cloud logging',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupTitle(BuildContext context, IconData icon, String title) {
    final scheme = Theme.of(context).colorScheme;
    final wide = isDesktopShell(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: scheme.primary),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              wide ? title : title.toUpperCase(),
              style: TextStyle(
                fontSize: wide ? 13 : 12,
                fontWeight: FontWeight.w700,
                letterSpacing: wide ? -0.1 : 0.6,
                color: scheme.primary,
              ),
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
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 16, color: selected ? scheme.onPrimary : scheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
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

  Future<void> _pickSaveFolder(
    BuildContext context,
    SettingsController controller,
    AppSettings settings,
  ) async {
    if (settings.saveTreeUri != null) {
      final choice = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.folder_open_rounded),
                title: const Text('Choose another folder'),
                onTap: () => Navigator.pop(context, 'pick'),
              ),
              ListTile(
                leading: const Icon(Icons.folder_off_outlined),
                title: const Text('Stop copying into that folder'),
                onTap: () => Navigator.pop(context, 'clear'),
              ),
            ],
          ),
        ),
      );
      if (!context.mounted || choice == null) return;
      if (choice == 'clear') {
        await controller.setSaveTree(null);
        return;
      }
    }
    final uri = await PhoneBody.pickFolder();
    if (uri == null) return;
    await controller.setSaveTree(uri);
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

Future<void> _pairLibrary(BuildContext context, WidgetRef ref) async {
  try {
    final records = await ref.read(downloadsRepositoryProvider).getAll();
    final items = <Map<String, String>>[];
    for (final record in records) {
      if (record.status.name != 'completed') continue;
      items.add({
        'title': record.title,
        'platform': record.platform.displayName,
        'source_url': record.sourceUrl,
        'quality': record.quality ?? '',
      });
    }
    if (items.isEmpty) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Save a video first. The code lists titles only.')),
      );
      return;
    }
    final code = await ref.read(mediaRepositoryProvider).createPair(items);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Library code'),
        content: Text(
          'On the SocialSave website, enter $code. It expires in 15 minutes and does not send the video file.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not create a library code.')),
    );
  }
}

Future<void> _exportIndex(BuildContext context, WidgetRef ref) async {
  final passphrase = await _askPassphrase(context, 'Encrypt this backup');
  if (passphrase == null || !context.mounted) return;
  try {
    final records = await ref.read(downloadsRepositoryProvider).getAll();
    final catalog = ref.read(libraryCatalogProvider);
    final payload = jsonEncode({
      'records': records.map((record) => record.toJson()).toList(),
      'catalog': catalog.encode(),
    });
    final bytes = await const IndexBackup().seal(payload, passphrase);
    if (DesktopSupport.isWindows) {
      final folder = await DesktopSupport.saveFolder();
      final saved = File('${folder.path}${Platform.pathSeparator}socialsave-library.socialsave');
      await saved.writeAsBytes(bytes, flush: true);
      await DesktopSupport.revealInFolder(saved.path);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Backup saved to ${saved.path}')),
      );
      return;
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}socialsave-library.socialsave');
    await file.writeAsBytes(bytes, flush: true);
    await Share.shareXFiles([XFile(file.path)], text: 'SocialSave library index');
  } on FormatException catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not create the backup.')),
    );
  }
}

Future<void> _importIndex(BuildContext context, WidgetRef ref) async {
  dynamic raw;
  if (DesktopSupport.isWindows) {
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'SocialSave backup', extensions: ['socialsave']),
      ],
    );
    raw = picked == null ? null : await picked.readAsBytes();
  } else {
    raw = await MediaEvents.channel.invokeMethod<dynamic>('pickBackup');
  }
  if (!context.mounted || raw == null) return;
  final bytes = raw is List ? raw.cast<int>() : null;
  if (bytes == null) return;
  final passphrase = await _askPassphrase(context, 'Unlock this backup');
  if (passphrase == null || !context.mounted) return;
  try {
    final text = await const IndexBackup().open(Uint8List.fromList(bytes), passphrase);
    final data = jsonDecode(text);
    if (data is! Map) throw const FormatException('This backup could not be read.');
    final records = data['records'];
    if (records is List) {
      final repo = ref.read(downloadsRepositoryProvider);
      for (final item in records) {
        if (item is Map) {
          await repo.upsert(DownloadRecord.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    final catalog = data['catalog'];
    if (catalog is String) {
      await ref.read(libraryCatalogProvider.notifier).replace(LibraryCatalog.decode(catalog));
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Library index restored. Video files stay where they were saved.')),
    );
  } on FormatException catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not restore that backup. Check the passphrase.')),
    );
  }
}

Future<String?> _askPassphrase(BuildContext context, String title) async {
  final controller = TextEditingController();
  final value = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'Passphrase'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  controller.dispose();
  return value?.trim().isEmpty == true ? null : value?.trim();
}

final ValueNotifier<String> _settingsQuery = ValueNotifier<String>('');

class _SettingsSearch extends StatelessWidget {
  const _SettingsSearch();

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const ValueKey('settings-search'),
      onChanged: (v) => _settingsQuery.value = v.trim().toLowerCase(),
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search_rounded),
        hintText: 'Search settings',
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}

/// A settings group that can be collapsed and is hidden when it does not
/// match the search box.
class _Sec extends StatefulWidget {
  const _Sec({required this.title, required this.keys, required this.child});
  final String title;
  final String keys;
  final Widget child;

  @override
  State<_Sec> createState() => _SecState();
}

class _SecState extends State<_Sec> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: _settingsQuery,
      builder: (context, q, _) {
        final hay = '${widget.title} ${widget.keys}'.toLowerCase();
        if (q.isNotEmpty && !hay.contains(q)) return const SizedBox.shrink();
        final open = _open || q.isNotEmpty;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              button: true,
              label: '${widget.title}, ${open ? 'expanded' : 'collapsed'}',
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: q.isNotEmpty ? null : () => setState(() => _open = !_open),
                  icon: Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
                  label: Text(open ? 'Collapse' : 'Show ${widget.title}'),
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              alignment: Alignment.topCenter,
              child: open ? widget.child : const SizedBox(width: double.infinity),
            ),
          ],
        );
      },
    );
  }
}
