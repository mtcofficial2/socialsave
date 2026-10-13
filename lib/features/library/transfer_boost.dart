import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Keeps transfers at full Wi-Fi speed.
///
/// * Android: holds a high-performance Wi-Fi lock while any transfer runs,
///   so Wi-Fi power saving does not throttle the radio (a common cause of
///   ~1-2 MB/s transfers on phones).
/// * Reads files in 1 MB pieces instead of 64 KB, so fewer, larger socket
///   writes go out.
class TransferBoost {
  TransferBoost._();

  static const _media = MethodChannel('socialsave/media');
  static int _active = 0;

  static Future<void> begin() async {
    _active++;
    if (_active == 1 && Platform.isAndroid) {
      try {
        await _media.invokeMethod<bool>('wifiLock', {'on': true});
      } catch (_) {}
    }
  }

  static Future<void> end() async {
    if (_active == 0) return;
    _active--;
    if (_active == 0 && Platform.isAndroid) {
      try {
        await _media.invokeMethod<bool>('wifiLock', {'on': false});
      } catch (_) {}
    }
  }

  /// Streams [file] (optionally the byte range [start, end)) in 1 MB chunks.
  static Stream<List<int>> read(File file, [int start = 0, int? end]) async* {
    const chunk = 1024 * 1024;
    final raf = await file.open();
    try {
      final stop = end ?? await raf.length();
      var pos = start;
      await raf.setPosition(pos);
      while (pos < stop) {
        final want = stop - pos < chunk ? stop - pos : chunk;
        final Uint8List data = await raf.read(want);
        if (data.isEmpty) break;
        pos += data.length;
        yield data;
      }
    } finally {
      await raf.close();
    }
  }
}
