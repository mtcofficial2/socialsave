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
  }
}
