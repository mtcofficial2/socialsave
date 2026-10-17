import 'dart:io';
import 'package:social_save/core/platform/plat.dart';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Keeps transfers at full Wi-Fi speed.
///
/// * Android: holds a high-performance Wi-Fi lock while any transfer runs,
///   so Wi-Fi power saving does not throttle the radio (a common cause of
///   ~1-2 MB/s transfers on phones).
/// * Reads files in 4 MB pieces with read-ahead, and writes received data
///   while the socket keeps reading (1.0.37).
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

  /// Read size for transfers. 1.0.37: 4 MB (was 1 MB) so the socket always
  /// has a full piece waiting.
  static const int chunkSize = 4 * 1024 * 1024;

  /// Streams [file] (optionally the byte range [start, end)) in 4 MB chunks.
  ///
  /// 1.0.37: reads ahead. The next piece is already being read from storage
  /// while the current one goes out on the socket, so the sender never waits
  /// on the disk between pieces (USB: see the 1.0.37 notes).
  static Stream<List<int>> read(File file, [int start = 0, int? end]) async* {
    final raf = await file.open();
    try {
      final stop = end ?? await raf.length();
      var pos = start;
      await raf.setPosition(pos);
      Future<Uint8List> next() {
        final want = stop - pos < chunkSize ? stop - pos : chunkSize;
        pos += want;
        return raf.read(want);
      }

      Future<Uint8List>? pending = pos < stop ? next() : null;
      while (pending != null) {
        final Uint8List data = await pending;
        if (data.isEmpty) break;
        // Start the following read before handing this piece on.
        pending = pos < stop ? next() : null;
        yield data;
      }
    } finally {
      await raf.close();
    }
  }
}

/// Writes an incoming stream to [dest] with back-pressure.
///
/// 1.0.37: pipelined. Incoming bytes are gathered into 4 MB blocks; a block
/// is written while the socket keeps being read into the next one. Only when
/// a second block is full before the first is on disk does reading pause, so
/// a fast sender still never piles gigabytes up in memory on a slower phone,
/// but the TCP window no longer closes on every disk write (1.0.36 paused the
/// socket for each 1 MB write).
/// Returns the bytes written; throws [FileSystemException] on disk errors.
Future<int> writeStreamToFile(Stream<List<int>> input, File dest, {void Function(int got)? onBytes}) async {
  const block = 4 * 1024 * 1024;
  final raf = await dest.open(mode: FileMode.write);
  final buffer = BytesBuilder(copy: false);
  Future<void>? writing;
  var got = 0;
  try {
    await for (final chunk in input) {
      buffer.add(chunk);
      got += chunk.length;
      if (buffer.length >= block) {
        // At most one write in flight: wait for the previous block only.
        if (writing != null) await writing;
        writing = raf.writeFrom(buffer.takeBytes()).then((_) {});
      }
      onBytes?.call(got);
    }
    if (writing != null) await writing;
    writing = null;
    if (buffer.length > 0) await raf.writeFrom(buffer.takeBytes());
    await raf.flush();
  } finally {
    if (writing != null) {
      try {
        await writing;
      } catch (_) {}
    }
    await raf.close();
  }
  return got;
}
