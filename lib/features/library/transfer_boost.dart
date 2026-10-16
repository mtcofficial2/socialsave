import 'dart:io';
import 'package:social_save/core/platform/plat.dart';
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
    if (_active == 1 && Plat.isAndroid) {
      try {
        await _media.invokeMethod<bool>('wifiLock', {'on': true});
      } catch (_) {}
    }
  }

  static Future<void> end() async {
    if (_active == 0) return;
    _active--;
    if (_active == 0 && Plat.isAndroid) {
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

/// Writes an incoming stream to [dest] with back-pressure: each 1 MB block is
/// awaited on disk before more is read from the socket, so a fast sender can
/// never pile gigabytes up in memory on a slower phone.
/// Returns the bytes written; throws [FileSystemException] on disk errors.
Future<int> writeStreamToFile(Stream<List<int>> input, File dest, {void Function(int got)? onBytes}) async {
  final raf = await dest.open(mode: FileMode.write);
  final buffer = BytesBuilder(copy: false);
  var got = 0;
  try {
    await for (final chunk in input) {
      buffer.add(chunk);
      got += chunk.length;
      if (buffer.length >= (1 << 20)) {
        await raf.writeFrom(buffer.takeBytes());
      }
      onBytes?.call(got);
    }
    if (buffer.length > 0) await raf.writeFrom(buffer.takeBytes());
    await raf.flush();
  } finally {
    await raf.close();
  }
  return got;
}
