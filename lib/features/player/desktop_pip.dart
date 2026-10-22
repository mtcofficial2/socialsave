import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// Picture in picture on Windows: the same window becomes a small,
/// borderless, always-on-top player in the bottom-right corner. The player
/// is never rebuilt, so playback carries on without a restart. Size and
/// position are remembered; leaving puts the window back where it was.
class DesktopPip {
  DesktopPip._();

  static Rect? _restore;
  static bool _wasMaximized = false;
  static bool active = false;

  /// True while the window grows back from the mini player, so layouts that
  /// key off the window width (the Library's dock) don't drop the player
  /// for the moment the window is still small.
  static bool restoring = false;

  static const _kX = 'pip.x';
  static const _kY = 'pip.y';
  static const _kW = 'pip.w';
  // Portrait (Shorts) keeps its own size: a landscape width reused for 9:16
  // made a window taller than the screen.
  static const _kWTall = 'pip.wTall';
  static bool _tall = false;

  static Size _screen() {
    final displays = ui.PlatformDispatcher.instance.displays;
    if (displays.isEmpty) return const Size(1366, 768);
    final d = displays.first;
    return Size(d.size.width / d.devicePixelRatio, d.size.height / d.devicePixelRatio);
  }

  static Future<void> enter({double aspect = 16 / 9}) async {
    if (active) return;
    final a = (aspect.isFinite && aspect > 0.3 && aspect < 4) ? aspect : 16 / 9;
    _wasMaximized = await windowManager.isMaximized();
    if (_wasMaximized) await windowManager.unmaximize();
    _restore = await windowManager.getBounds();
    final prefs = await SharedPreferences.getInstance();
    final screen = _screen();
    _tall = a < 1;
    var w = prefs.getDouble(_tall ? _kWTall : _kW) ?? (_tall ? 240.0 : 400.0);
    // Fit both edges: at most 60% of the screen wide and 55% tall.
    final maxW = math.min(screen.width * 0.6, screen.height * 0.55 * a);
    final minW = math.min(_tall ? 140.0 : 220.0, maxW);
    w = w.clamp(minW, maxW);
    final h = w / a;
    var x = prefs.getDouble(_kX) ?? (screen.width - w - 24);
    var y = prefs.getDouble(_kY) ?? (screen.height - h - 72);
    x = x.clamp(0.0, screen.width - w);
    y = y.clamp(0.0, screen.height - h);
    active = true;
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
    // Minimum keeps the video's shape, so a portrait window can shrink too.
    await windowManager.setMinimumSize(a >= 1 ? Size(200, 200 / a) : Size(112 * a, 112));
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setBounds(Rect.fromLTWH(x, y, w, h));
    await windowManager.setAspectRatio(a);
  }

  static Future<void> exit() async {
    if (!active) return;
    active = false;
    restoring = true;
    try {
      final now = await windowManager.getBounds();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kX, now.left);
      await prefs.setDouble(_kY, now.top);
      await prefs.setDouble(_tall ? _kWTall : _kW, now.width);
    } catch (_) {}
    await windowManager.setAspectRatio(0);
    await windowManager.setMinimumSize(const Size(360, 480));
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    final r = _restore;
    if (r != null) await windowManager.setBounds(r);
    if (_wasMaximized) await windowManager.maximize();
    await windowManager.focus();
    Future<void>.delayed(const Duration(seconds: 1), () => restoring = false);
  }
}