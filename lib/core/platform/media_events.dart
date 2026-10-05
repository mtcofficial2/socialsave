import 'package:flutter/services.dart';

/// One handler for native callbacks so features do not replace each other.
class MediaEvents {
  MediaEvents._();

  static const channel = MethodChannel('socialsave/media');
  static final Map<String, Future<void> Function(dynamic args)> _handlers = {};
  static var _installed = false;

  static void on(String method, Future<void> Function(dynamic args) handler) {
    _install();
    _handlers[method] = handler;
  }

  static void off(String method) {
    _handlers.remove(method);
  }

  static void _install() {
    if (_installed) return;
    _installed = true;
    channel.setMethodCallHandler((call) async {
      final handler = _handlers[call.method];
      if (handler != null) {
        await handler(call.arguments);
      }
    });
  }
}
