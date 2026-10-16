import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/library/hotspot_share.dart';
import 'package:social_save/features/library/session_ui.dart';
import 'package:social_save/features/library/share_session.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Windows: while connected (or hosting a hotspot) SocialSave sits in the
/// system tray with a status tooltip and Open / Disconnect. Closing the
/// window then only hides it, so the session keeps running; minimising
/// never stopped it. Without a session the window closes exactly as before.
class DesktopTray with TrayListener, WindowListener {
  DesktopTray._();
  static final DesktopTray instance = DesktopTray._();

  static bool _installed = false;
  bool _shown = false;
  bool _hiddenByClose = false;
  String _tip = '';
  Timer? _tipTimer;

  static Future<void> install() async {
    if (_installed || kIsWeb || !Plat.isWindows) return;
    _installed = true;
    try {
      await windowManager.ensureInitialized();
      windowManager.addListener(instance);
      trayManager.addListener(instance);
    } catch (e) {
      debugPrint('[tray] init failed: $e');
      return;
    }
    for (final l in [ShareSession.peer, ShareSession.state, ShareSession.revision, HotspotShare.hostRunning]) {
      l.addListener(instance._sync);
    }
  }

  bool get _active => ShareSession.active || HotspotShare.hostRunning.value;

  void _sync() {
    unawaited(_apply());
  }

  Future<void> _apply() async {
    try {
      if (_active && !_shown) {
        _shown = true;
        await trayManager.setIcon('assets/tray/app_icon.ico');
        await windowManager.setPreventClose(true);
        await _menu();
      }
      if (_active) {
        final tip = ShareSession.active
            ? '${ShareSession.statusTitle} · ${ShareSession.statusText}'
            : 'SocialSave · PC hotspot on, waiting for a phone';
        final t = tip.length > 120 ? '${tip.substring(0, 119)}…' : tip;
        if (t != _tip) {
          _tip = t;
          _tipTimer ??= Timer(const Duration(milliseconds: 800), () async {
            _tipTimer = null;
            try {
              await trayManager.setToolTip(_tip);
              await _menu();
            } catch (_) {}
          });
        }
      } else if (_shown) {
        _shown = false;
        _tipTimer?.cancel();
        _tipTimer = null;
        _tip = '';
        await trayManager.destroy();
        await windowManager.setPreventClose(false);
        if (_hiddenByClose) {
          // The window was closed while connected; the session is over now.
          await windowManager.destroy();
        }
      }
    } catch (e) {
      debugPrint('[tray] $e');
    }
  }

  Future<void> _menu() async {
    final p = ShareSession.peer.value;
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'status', label: p == null ? 'SocialSave' : ShareSession.statusTitle, disabled: true),
      MenuItem.separator(),
      MenuItem(key: 'open', label: 'Open SocialSave'),
      if (p != null || HotspotShare.hostRunning.value) MenuItem(key: 'disconnect', label: p == null ? 'Stop hotspot' : 'Disconnect from ${p.name}'),
    ]));
  }

  Future<void> _showWindow({bool session = false}) async {
    _hiddenByClose = false;
    await windowManager.show();
    await windowManager.restore();
    await windowManager.focus();
    if (session && ShareSession.active) unawaited(openSessionScreen());
  }

  @override
  void onWindowClose() {
    unawaited(() async {
      if (_active) {
        // Keep the session: hide to the tray.
        _hiddenByClose = true;
        await windowManager.hide();
      } else {
        await windowManager.setPreventClose(false);
        await windowManager.destroy();
      }
    }());
  }

  @override
  void onTrayIconMouseDown() => unawaited(_showWindow(session: true));

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        unawaited(_showWindow(session: true));
      case 'disconnect':
        unawaited(() async {
          if (ShareSession.active) {
            await ShareSession.disconnect();
          } else {
            await HotspotShare.stop();
          }
        }());
    }
  }
}
