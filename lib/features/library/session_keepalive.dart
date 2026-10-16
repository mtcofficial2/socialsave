import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:social_save/core/platform/plat.dart';

/// Android side of a connected session: a foreground service with a
/// persistent "Connected to …" notification (Open / Disconnect), wake and
/// Wi-Fi locks, "file received" notifications and the battery-optimisation
/// exemption. Does nothing on Windows (the app keeps running while the
/// window is minimised).
class SessionKeepAlive {
  SessionKeepAlive._();

  static const _channel = MethodChannel('socialsave/session');
  static bool _wired = false;
  static bool _running = false;
  static String _lastTitle = '';
  static String _lastText = '';
  static DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  static Timer? _pending;

  /// Notification "Disconnect" was tapped.
  static Future<void> Function()? onDisconnect;

  /// Notification (or its "Open" action) was tapped.
  static void Function()? onOpen;

  static bool get supported => !kIsWeb && Plat.isAndroid;

  static void wire() {
    if (_wired || !supported) return;
    _wired = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'disconnect':
          await onDisconnect?.call();
        case 'open':
          onOpen?.call();
      }
      return null;
    });
    // Opened from the notification while the app was starting.
    unawaited(Future<void>.delayed(const Duration(seconds: 2), () async {
      try {
        if (await _channel.invokeMethod<bool>('takeOpen') == true) onOpen?.call();
      } catch (_) {}
    }));
  }

  /// Starts (or refreshes) the foreground service.
  static Future<void> start(String title, String text) async {
    if (!supported) return;
    wire();
    _running = true;
    _lastTitle = title;
    _lastText = text;
    _lastSent = DateTime.now();
    try {
      await _channel.invokeMethod<bool>('start', {'title': title, 'text': text});
    } catch (e) {
      debugPrint('[session] keep-alive start failed: $e');
    }
  }

  /// Updates the notification text, at most about once a second.
  static void update(String title, String text) {
    if (!supported || !_running) return;
    if (title == _lastTitle && text == _lastText) return;
    _lastTitle = title;
    _lastText = text;
    _pending?.cancel();
    final wait = const Duration(milliseconds: 1000) - DateTime.now().difference(_lastSent);
    _pending = Timer(wait.isNegative ? Duration.zero : wait, () {
      _lastSent = DateTime.now();
      if (!_running) return;
      unawaited(_channel.invokeMethod<bool>('update', {'title': _lastTitle, 'text': _lastText}).catchError((_) => false));
    });
  }

  static Future<void> stop() async {
    if (!supported) return;
    _pending?.cancel();
    if (!_running) return;
    _running = false;
    try {
      await _channel.invokeMethod<bool>('stop');
    } catch (_) {}
  }

  static Future<void> received(String title, String text) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<bool>('received', {'title': title, 'text': text});
    } catch (_) {}
  }

  static Future<bool> batteryExempt() async {
    if (!supported) return true;
    try {
      return await _channel.invokeMethod<bool>('batteryExempt') ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> requestBatteryExempt() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<bool>('requestBatteryExempt');
    } catch (_) {}
  }
}
