import 'package:flutter/foundation.dart';

/// The in-app player registers here so a second screen can be controlled
/// from the phone without sending the file anywhere.
class PlaybackBridge {
  PlaybackBridge._();

  static final attached = ValueNotifier<bool>(false);
  static Object? _owner;
  static String Function()? title;
  static bool Function()? playing;
  static Future<void> Function()? toggle;
  static Future<void> Function(int seconds)? seek;
  static Future<void> Function()? next;

  static void bind({
    required Object owner,
    required String Function() title,
    required bool Function() playing,
    required Future<void> Function() toggle,
    required Future<void> Function(int seconds) seek,
    required Future<void> Function() next,
  }) {
    _owner = owner;
    PlaybackBridge.title = title;
    PlaybackBridge.playing = playing;
    PlaybackBridge.toggle = toggle;
    PlaybackBridge.seek = seek;
    PlaybackBridge.next = next;
    attached.value = true;
  }

  static void clear(Object owner) {
    if (_owner != owner) return;
    _owner = null;
    title = null;
    playing = null;
    toggle = null;
    seek = null;
    next = null;
    attached.value = false;
  }
}
