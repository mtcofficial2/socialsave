import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/features/settings/domain/entities/app_settings.dart';
import 'package:social_save/features/settings/domain/repositories/settings_repository.dart';

class SharedPreferencesSettingsStore implements SettingsRepository {
  SharedPreferencesSettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static const _themeMode = '${AppConstants.settingsPrefsPrefix}themeMode';
  static const _downloadLocation =
      '${AppConstants.settingsPrefsPrefix}downloadLocation';
  static const _wifiOnly = '${AppConstants.settingsPrefsPrefix}wifiOnly';
  static const _autoStart =
      '${AppConstants.settingsPrefsPrefix}autoStartDownloads';
  static const _notifications =
      '${AppConstants.settingsPrefsPrefix}notificationsEnabled';
  static const _quality = '${AppConstants.settingsPrefsPrefix}defaultQuality';
  static const _format = '${AppConstants.settingsPrefsPrefix}defaultFormat';
  static const _fontFamily = '${AppConstants.settingsPrefsPrefix}fontFamily';
  static const _autoPlayNext =
      '${AppConstants.settingsPrefsPrefix}autoPlayNextInGallery';
  static const _lastQuality =
      '${AppConstants.settingsPrefsPrefix}lastChosenQuality';
  static const _qualityByPlatform =
      '${AppConstants.settingsPrefsPrefix}qualityByPlatform';
  static const _dynamicColor =
      '${AppConstants.settingsPrefsPrefix}useDynamicColor';

  @override
  Future<AppSettings> load() async {
    return AppSettings.fromMap({
      'themeMode': _prefs.getString(_themeMode),
      'downloadLocation': _prefs.getString(_downloadLocation),
      'wifiOnly': _prefs.getBool(_wifiOnly),
      'autoStartDownloads': _prefs.getBool(_autoStart),
      'notificationsEnabled': _prefs.getBool(_notifications),
      'defaultQuality': _prefs.getString(_quality),
      'defaultFormat': _prefs.getString(_format),
      'fontFamily': _prefs.getString(_fontFamily),
      'autoPlayNextInGallery': _prefs.getBool(_autoPlayNext),
      'lastChosenQuality': _prefs.getString(_lastQuality),
      'qualityByPlatform': _decodePlatforms(_prefs.getString(_qualityByPlatform)),
      'useDynamicColor': _prefs.getBool(_dynamicColor),
    });
  }

  @override
  Future<void> save(AppSettings settings) async {
    await _prefs.setString(_themeMode, settings.themeMode.name);
    await _prefs.setString(
      _downloadLocation,
      settings.downloadLocation.name,
    );
    await _prefs.setBool(_wifiOnly, settings.wifiOnly);
    await _prefs.setBool(_autoStart, settings.autoStartDownloads);
    await _prefs.setBool(_notifications, settings.notificationsEnabled);
    await _prefs.setString(_quality, settings.defaultQuality.name);
    await _prefs.setString(_format, settings.defaultFormat.name);
    await _prefs.setString(_fontFamily, settings.fontFamily);
    await _prefs.setBool(_autoPlayNext, settings.autoPlayNextInGallery);
    final last = settings.lastChosenQuality;
    if (last == null || last.isEmpty) {
      await _prefs.remove(_lastQuality);
    } else {
      await _prefs.setString(_lastQuality, last);
    }
    await _prefs.setString(
      _qualityByPlatform,
      jsonEncode(settings.qualityByPlatform),
    );
    await _prefs.setBool(_dynamicColor, settings.useDynamicColor);
  }

  Map<String, String> _decodePlatforms(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final data = jsonDecode(raw);
      if (data is! Map) return const {};
      return data.map((key, value) => MapEntry('$key', '$value'));
    } catch (_) {
      return const {};
    }
  }
}
