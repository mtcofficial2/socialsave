import 'package:flutter/services.dart';

class PipController {
  static const _channel = MethodChannel('socialsave/media');

  static Future<void> setAllowed(bool allowed) async {
    try {
      await _channel.invokeMethod<void>('setPipAllowed', {'allowed': allowed});
    } catch (_) {}
  }

  static Future<void> setAspect(int width, int height) async {
    try {
      await _channel.invokeMethod<void>('setPipAspect', {
        'width': width,
        'height': height,
      });
    } catch (_) {}
  }

  static Future<bool> enter() async {
    try {
      return await _channel.invokeMethod<bool>('enterPip') ?? false;
    } catch (_) {
      return false;
    }
  }

  static void listen(void Function(bool inPip) onChanged) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pipChanged') {
        onChanged(call.arguments == true);
      }
    });
  }

  static void clearListener() {
    _channel.setMethodCallHandler(null);
  }
}
