import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Chat choices stored on this device. Mute stays on each conversation.
class ChatPrefs {
  ChatPrefs._();

  static const _enterKey = 'chat.pref.enter.v1';
  static const _soundKey = 'chat.pref.sound.v1';
  static const _patternKey = 'chat.pref.pattern.v1';

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Null keeps the keyboard behavior this app already ships.
  static bool? enterOverride;
  static bool messageSound = true;

  /// A plain canvas is the default. The pattern is optional.
  static bool pattern = false;
  static Future<void>? _loading;

  static Future<void> ensure() {
    return _loading ??= _read();
  }

  /// Enter sends. Shift+Enter stays a new line on a computer.
  /// A phone uses its Send key unless this is turned off.
  static bool get keyboardSends => keyboardSendsValue(enterOverride);

  static bool keyboardSendsValue(bool? stored) => stored ?? true;

  static bool imeSends({
    required bool keyboardSends,
    required TargetPlatform platform,
  }) {
    if (!keyboardSends) return false;
    switch (platform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return true;
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
        return false;
    }
  }

  /// Desktop Enter is handled here so Shift+Enter can stay a new line.
  static bool hardwareEnterSends({
    required bool keyboardSends,
    required TargetPlatform platform,
  }) {
    if (!keyboardSends) return false;
    return !imeSends(keyboardSends: keyboardSends, platform: platform);
  }

  static Future<void> setKeyboardSends(bool on) async {
    await ensure();
    enterOverride = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enterKey, on);
    revision.value++;
  }

  static Future<void> setMessageSound(bool on) async {
    await ensure();
    messageSound = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_soundKey, on);
    revision.value++;
  }

  static Future<void> setPattern(bool on) async {
    await ensure();
    pattern = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_patternKey, on);
    revision.value++;
  }

  static Future<void> _read() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(_enterKey)) {
      enterOverride = prefs.getBool(_enterKey);
    }
    messageSound = prefs.getBool(_soundKey) ?? true;
    pattern = prefs.getBool(_patternKey) ?? false;
    revision.value++;
  }
}
