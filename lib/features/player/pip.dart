import 'package:social_save/core/platform/media_events.dart';
import 'package:social_save/core/diagnostics/quiet_log.dart';

class PipController {
  static Future<void> setAllowed(bool allowed) async {
    try {
      await MediaEvents.channel.invokeMethod<void>('setPipAllowed', {'allowed': allowed});
    } catch (e) { logQuiet('pip', e); }
  }

  static Future<void> setAspect(int width, int height) async {
    try {
      await MediaEvents.channel.invokeMethod<void>('setPipAspect', {
        'width': width,
        'height': height,
      });
    } catch (e) { logQuiet('pip', e); }
  }

  static Future<bool> enter() async {
    try {
      return await MediaEvents.channel.invokeMethod<bool>('enterPip') ?? false;
    } catch (_) {
      return false;
    }
  }

  static void listen(void Function(bool inPip) onChanged) {
    MediaEvents.on('pipChanged', (args) async {
      onChanged(args == true);
    });
  }

  static void clearListener() {
    MediaEvents.off('pipChanged');
  }
}
