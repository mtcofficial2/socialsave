import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Chat choices stored on this device. Mute stays on each conversation.
class ChatPrefs {
  ChatPrefs._();

  static const _enterKey = 'chat.pref.enter.v1';
  static const _soundKey = 'chat.pref.sound.v1';
  static const _popupKey = 'chat.pref.popup.v1';
  static const _patternKey = 'chat.pref.pattern.v1';
  static const _quietKey = 'chat.pref.quiet.v1';
  static const _saverKey = 'chat.pref.saver.v1';
  static const _notifyKey = 'chat.pref.notify.v1';
  static const _wifiUpdateKey = 'chat.pref.wifiUpdate.v1';

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Null keeps the keyboard behavior this app already ships.
  static bool? enterOverride;
  static bool messageSound = true;

  /// The green card over other apps. Off leaves the normal notification.
  static bool messagePopup = true;

  /// A plain canvas is the default. The pattern is optional.
  static bool pattern = false;

  /// Minutes from midnight. Equal or negative values mean quiet hours are off.
  static int quietStart = -1;
  static int quietEnd = -1;

  /// Holds message photos until a tap, and checks for new messages less often.
  static bool dataSaver = false;

  /// On Wi-Fi, a newer Android build downloads and the install screen opens.
  static bool wifiUpdate = true;

  /// Per conversation: all, mentions, or silent. Missing means all.
  static final Map<String, String> notifyMode = {};
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

  /// Missing means the green card still shows.
  static bool messagePopupValue(bool? stored) => stored ?? true;

  static Future<void> setMessagePopup(bool on) async {
    await ensure();
    messagePopup = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_popupKey, on);
    revision.value++;
  }

  static Future<void> setPattern(bool on) async {
    await ensure();
    pattern = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_patternKey, on);
    revision.value++;
  }

  /// [start] and [end] are minutes from midnight. The window can pass midnight.
  static bool minutesQuiet(int start, int end, int minute) {
    if (start < 0 || end < 0 || start >= 24 * 60 || end >= 24 * 60) {
      return false;
    }
    if (start == end) return false;
    if (start < end) return minute >= start && minute < end;
    return minute >= start || minute < end;
  }

  static bool quietNow([DateTime? clock]) {
    final now = clock ?? DateTime.now();
    return minutesQuiet(quietStart, quietEnd, now.hour * 60 + now.minute);
  }

  static String modeFor(String threadId) => notifyMode[threadId] ?? 'all';

  /// Mentions mode still notifies a direct chat. A group notifies on @name.
  static bool showsNotice({
    required String threadId,
    required bool group,
    required String text,
    required String me,
  }) {
    if (modeFor(threadId) != 'mentions') return true;
    if (!group) return true;
    final name = me.replaceFirst(RegExp(r'^@'), '').trim().toLowerCase();
    if (name.isEmpty) return false;
    return text.toLowerCase().contains('@$name');
  }

  /// Quiet hours and a silent chat turn the tone off. The notice still shows.
  static bool soundAllowed(String threadId) {
    if (!messageSound || quietNow()) return false;
    return modeFor(threadId) != 'silent';
  }

  static Future<void> setQuiet({required int start, required int end}) async {
    await ensure();
    quietStart = start;
    quietEnd = end;
    final prefs = await SharedPreferences.getInstance();
    if (start < 0 || end < 0 || start == end) {
      await prefs.remove(_quietKey);
    } else {
      await prefs.setString(_quietKey, '$start,$end');
    }
    revision.value++;
  }

  /// Missing means the Wi-Fi update stays on.
  static bool wifiUpdateValue(bool? stored) => stored ?? true;

  static Future<void> setWifiUpdate(bool on) async {
    await ensure();
    wifiUpdate = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_wifiUpdateKey, on);
    revision.value++;
  }

  static Future<void> setDataSaver(bool on) async {
    await ensure();
    dataSaver = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_saverKey, on);
    revision.value++;
  }

  static Future<void> setNotify(String threadId, String mode) async {
    await ensure();
    if (threadId.isEmpty) return;
    if (mode == 'all') {
      notifyMode.remove(threadId);
    } else if (mode == 'mentions' || mode == 'silent') {
      notifyMode[threadId] = mode;
    }
    final prefs = await SharedPreferences.getInstance();
    final lines = [
      for (final entry in notifyMode.entries) '${entry.key}|${entry.value}',
    ];
    if (lines.isEmpty) {
      await prefs.remove(_notifyKey);
    } else {
      await prefs.setString(_notifyKey, lines.join('\n'));
    }
    revision.value++;
  }

  static Future<void> _read() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(_enterKey)) {
      enterOverride = prefs.getBool(_enterKey);
    }
    messageSound = prefs.getBool(_soundKey) ?? true;
    messagePopup = messagePopupValue(prefs.getBool(_popupKey));
    pattern = prefs.getBool(_patternKey) ?? false;
    dataSaver = prefs.getBool(_saverKey) ?? false;
    wifiUpdate = wifiUpdateValue(prefs.getBool(_wifiUpdateKey));
    final quiet = prefs.getString(_quietKey) ?? '';
    final parts = quiet.split(',');
    if (parts.length == 2) {
      quietStart = int.tryParse(parts[0]) ?? -1;
      quietEnd = int.tryParse(parts[1]) ?? -1;
    } else {
      quietStart = -1;
      quietEnd = -1;
    }
    notifyMode.clear();
    final saved = prefs.getString(_notifyKey) ?? '';
    for (final line in saved.split('\n')) {
      final cut = line.split('|');
      if (cut.length != 2) continue;
      final id = cut[0].trim();
      final mode = cut[1].trim();
      if (id.isEmpty) continue;
      if (mode == 'mentions' || mode == 'silent') notifyMode[id] = mode;
    }
    revision.value++;
  }
}
