import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/storage/download_path_service.dart';
import 'package:social_save/features/settings/domain/entities/app_settings.dart';

final settingsControllerProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    return ref.read(initialSettingsProvider);
  }

  Future<void> setThemeMode(ThemeMode mode) {
    return _commit(state.copyWith(themeMode: mode));
  }

  Future<void> setDownloadLocation(DownloadLocation location) {
    return _commit(state.copyWith(downloadLocation: location));
  }

  Future<void> setWifiOnly(bool value) {
    return _commit(state.copyWith(wifiOnly: value));
  }

  Future<void> setAutoStart(bool value) {
    return _commit(state.copyWith(autoStartDownloads: value));
  }

  Future<void> setNotifications(bool value) {
    return _commit(state.copyWith(notificationsEnabled: value));
  }

  Future<void> setDefaultQuality(VideoQualityPreference value) {
    return _commit(state.copyWith(defaultQuality: value));
  }

  Future<void> setDefaultFormat(VideoFormatPreference value) {
    return _commit(state.copyWith(defaultFormat: value));
  }

  Future<void> _commit(AppSettings next) async {
    state = next;
    await ref.read(settingsRepositoryProvider).save(next);
  }
}
