import 'dart:async';

import 'package:flutter/services.dart';
import 'package:social_save/core/platform/media_events.dart';

class PhoneSnapshot {
  const PhoneSnapshot({
    required this.battery,
    required this.charging,
    required this.pocket,
    required this.faceDown,
    required this.screenOff,
    required this.externalDisplay,
    required this.known,
  });

  final int battery;
  final bool charging;
  final bool pocket;
  final bool faceDown;
  final bool screenOff;
  final bool externalDisplay;
  final bool known;

  static const unknown = PhoneSnapshot(
    battery: -1,
    charging: false,
    pocket: false,
    faceDown: false,
    screenOff: false,
    externalDisplay: false,
    known: false,
  );

  factory PhoneSnapshot.fromMap(Map<Object?, Object?> map) {
    return PhoneSnapshot(
      battery: (map['battery'] as num?)?.toInt() ?? -1,
      charging: map['charging'] == true,
      pocket: map['pocket'] == true,
      faceDown: map['faceDown'] == true,
      screenOff: map['screenOff'] == true,
      externalDisplay: map['externalDisplay'] == true,
      known: map['known'] != false,
    );
  }
}

class PhoneAction {
  const PhoneAction(this.name, this.delta);

  final String name;
  final int delta;
}

class PhoneClipResult {
  const PhoneClipResult({
    required this.ok,
    this.needsSettings = false,
    this.message = '',
  });

  final bool ok;
  final bool needsSettings;
  final String message;
}

/// Battery, pocket, headset, and display events from the Android shell.
class PhoneBody {
  PhoneBody._();

  static const _events = EventChannel('socialsave/phone');
  static final snapshots = StreamController<PhoneSnapshot>.broadcast();
  static final actions = StreamController<PhoneAction>.broadcast();
  static PhoneSnapshot latest = PhoneSnapshot.unknown;
  static var _listening = false;

  static void ensure() {
    if (_listening) return;
    _listening = true;
    try {
      _events.receiveBroadcastStream().listen(
        (event) {
          if (event is! Map) return;
          final type = '${event['type']}';
          if (type == 'action') {
            final name = '${event['action']}';
            final delta = (event['delta'] as num?)?.toInt() ?? 0;
            if (!actions.isClosed) {
              actions.add(PhoneAction(name, delta));
            }
            return;
          }
          latest = PhoneSnapshot.fromMap(event);
          if (!snapshots.isClosed) snapshots.add(latest);
        },
        onError: (_) {},
      );
    } catch (_) {
      _listening = false;
    }
  }

  static Future<void> setPlayback({
    required bool active,
    required bool playing,
    required String title,
    required bool headset,
    required bool volumeSeek,
  }) async {
    try {
      await MediaEvents.channel.invokeMethod<void>('setPlaybackSession', {
        'active': active,
        'playing': playing,
        'title': title,
        'headset': headset,
        'volumeSeek': volumeSeek,
      });
    } catch (_) {}
  }

  static Future<void> vibrate({required bool saved}) async {
    try {
      await MediaEvents.channel.invokeMethod<void>('vibrate', {
        'pattern': saved ? 'saved' : 'failed',
      });
    } catch (_) {}
  }

  static Future<String?> pickFolder() async {
    try {
      final uri = await MediaEvents.channel.invokeMethod<String>('pickSaveFolder');
      if (uri == null || uri.isEmpty) return null;
      return uri;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> copyIntoFolder({
    required String treeUri,
    required String path,
    required String name,
  }) async {
    try {
      final saved = await MediaEvents.channel.invokeMethod<String>('copyIntoFolder', {
        'treeUri': treeUri,
        'path': path,
        'name': name,
      });
      if (saved == null || saved.isEmpty) return null;
      return saved;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> playOnTv({required String path, String? title}) async {
    try {
      final ok = await MediaEvents.channel.invokeMethod<bool>('playOnTv', {
        'path': path,
        'title': title,
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  static Future<PhoneClipResult> clipSound({
    required String path,
    required String kind,
  }) async {
    try {
      final raw = await MediaEvents.channel.invokeMethod<Object?>('clipSound', {
        'path': path,
        'kind': kind,
      });
      if (raw is! Map) {
        return const PhoneClipResult(
          ok: false,
          message: 'Could not make that sound on this phone.',
        );
      }
      return PhoneClipResult(
        ok: raw['ok'] == true,
        needsSettings: raw['needsSettings'] == true,
        message: '${raw['message'] ?? ''}',
      );
    } catch (_) {
      return const PhoneClipResult(
        ok: false,
        message: 'Could not make that sound on this phone.',
      );
    }
  }

  /// [value] from 0 to 1 dims the window. A negative value restores the system brightness.
  static Future<void> setBrightness(double value) async {
    try {
      await MediaEvents.channel.invokeMethod<void>('setBrightness', {
        'value': value,
      });
    } catch (_) {}
  }
}
