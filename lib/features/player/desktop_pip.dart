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

  static const _kX = 'pip.x';
  static const _kY = 'pip.y';
  static const _kW = 'pip.w';

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
    var w = prefs.getDouble(_kW) ?? (a >= 1 ? 400.0 : 240.0);
    w = w.clamp(220.0, screen.width * 0.6);
    final h = w / a;
    var x = prefs.getDouble(_kX) ?? (screen.width - w - 24);
    var y = prefs.getDouble(_kY) ?? (screen.height - h - 72);
    x = x.clamp(0.0, screen.width - w);
    y = y.clamp(0.0, screen.height - h);
    active = true;
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
    await windowManager.setMinimumSize(const Size(200, 112));
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setBounds(Rect.fromLTWH(x, y, w, h));
    await windowManager.setAspectRatio(a);
  }

  static Future<void> exit() async {
    if (!active) return;
    active = false;
    try {
      final now = await windowManager.getBounds();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kX, now.left);
      await prefs.setDouble(_kY, now.top);
      await prefs.setDouble(_kW, now.width);
    } catch (_) {}
    await windowManager.setAspectRatio(0);
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    final r = _restore;
    if (r != null) await windowManager.setBounds(r);
    if (_wasMaximized) await windowManager.maximize();
    await windowManager.focus();
  }
}