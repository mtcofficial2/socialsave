import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:social_save/core/platform/media_events.dart';
import 'package:social_save/core/platform/plat.dart';

/// Result of rewriting one picture's camera details.
class DevicePhotoResult {
  const DevicePhotoResult({required this.path, required this.copied, this.model = ''});

  final String path;
  final bool copied;
  final String model;
}

/// True for a still photo this feature can take. Animated GIF is left alone.
bool isStillPhotoPath(String? path, [String? format]) {
  final name = (path ?? '').toLowerCase();
  final kind = (format ?? '').toLowerCase();
  const ext = ['.jpg', '.jpeg', '.png', '.webp', '.heic', '.heif', '.bmp'];
  if (ext.any(name.endsWith)) return true;
  const kinds = {'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif', 'bmp', 'image', 'image/jpeg', 'image/png', 'image/webp'};
  return kinds.contains(kind);
}

/// Replaces camera, author, and site details with this device.
/// On Android a JPEG is updated in place. A PNG, WebP, or HEIC becomes a new JPEG.
Future<DevicePhotoResult> stampDevicePhoto(String path) async {
  if (Plat.isAndroid) {
    final raw = await MediaEvents.channel.invokeMapMethod<String, dynamic>('stampDevicePhoto', {'path': path});
    final out = raw?['path'] as String?;
    if (out == null || out.isEmpty) {
      throw const FormatException('Could not update that picture.');
    }
    return DevicePhotoResult(
      path: out,
      copied: raw?['copied'] == true,
      model: (raw?['model'] as String?) ?? '',
    );
  }
  final file = File(path);
  if (!file.existsSync()) {
    throw const FormatException('That picture is not on this device.');
  }
  final lower = path.toLowerCase();
  if (lower.endsWith('.gif')) {
    throw const FormatException('An animated picture stays as it is. Choose a still photo.');
  }
  if (!lower.endsWith('.jpg') && !lower.endsWith('.jpeg')) {
    throw const FormatException('On this computer, choose a JPEG. A photo from the internet usually is one.');
  }
  final stamped = stampJpeg(
    await file.readAsBytes(),
    make: 'Windows',
    model: Platform.environment['COMPUTERNAME'] ?? Platform.localHostname,
  );
  await file.writeAsBytes(stamped, flush: true);
  return DevicePhotoResult(path: file.path, copied: false, model: Platform.localHostname);
}

/// Asks for any still photo, then updates its camera details.
Future<void> stampPhotoFromPicker(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  String? path;
  if (Plat.isAndroid) {
    try {
      final picked = await MediaEvents.channel.invokeMapMethod<String, dynamic>('pickImage');
      path = picked?['path'] as String?;
    } on PlatformException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message ?? 'Could not open that picture.')));
      return;
    }
  } else {
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Photos', extensions: ['jpg', 'jpeg', 'png', 'webp', 'heic', 'bmp']),
      ],
    );
    path = picked?.path;
  }
  if (path == null || path.isEmpty || !context.mounted) return;
  await useDeviceCameraDetails(context, path);
}

/// Updates one saved picture and says what happened.
Future<void> useDeviceCameraDetails(BuildContext context, String path) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(const SnackBar(content: Text('Updating camera details…')));
  try {
    final result = await stampDevicePhoto(path);
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    final where = result.model.isEmpty ? 'this device' : result.model;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.copied
              ? 'A copy now says $where took it.'
              : 'This picture now says $where took it.',
        ),
      ),
    );
  } on PlatformException catch (error) {
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(error.message ?? 'Could not update that picture.')));
  } on FormatException catch (error) {
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(error.message)));
  } catch (_) {
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(const SnackBar(content: Text('Could not update that picture.')));
  }
}

/// Replaces JPEG camera metadata. Pixels, and a turn tag if the file has one, stay.
/// XMP and IPTC blocks that name another camera or site are removed.
Uint8List stampJpeg(
  Uint8List bytes, {
  required String make,
  required String model,
  DateTime? captured,
}) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    throw const FormatException('Choose a JPEG photo.');
  }
  final orientation = _orientationOf(bytes);
  final when = captured ?? DateTime.now();
  final out = BytesBuilder(copy: false);
  out.add(const [0xFF, 0xD8]);
  var i = 2;
  // Keep a JFIF header immediately after the start. Camera details follow it.
  while (i + 3 < bytes.length && bytes[i] == 0xFF && bytes[i + 1] == 0xE0) {
    final length = (bytes[i + 2] << 8) | bytes[i + 3];
    final span = 2 + length;
    if (length < 2 || i + span > bytes.length) break;
    out.add(bytes.sublist(i, i + span));
    i += span;
  }
  out.add(_exifSegment(make: make, model: model, when: when, orientation: orientation));
  while (i + 1 < bytes.length) {
    if (bytes[i] != 0xFF) {
      out.add(bytes.sublist(i));
      return out.toBytes();
    }
    final marker = bytes[i + 1];
    if (marker == 0xDA || marker == 0xD9) {
      out.add(bytes.sublist(i));
      return out.toBytes();
    }
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
      out.add(bytes.sublist(i, i + 2));
      i += 2;
      continue;
    }
    if (i + 3 >= bytes.length) break;
    final length = (bytes[i + 2] << 8) | bytes[i + 3];
    final span = 2 + length;
    if (length < 2 || i + span > bytes.length) {
      throw const FormatException('This JPEG could not be updated.');
    }
    final drop = marker == 0xED || (marker == 0xE1 && (_isExif(bytes, i + 4, length - 2) || _isXmp(bytes, i + 4, length - 2)));
    if (!drop) out.add(bytes.sublist(i, i + span));
    i += span;
  }
  throw const FormatException('This JPEG could not be updated.');
}

/// Reads the camera name written by [stampJpeg]. Used to check the file.
({String make, String model, int orientation}) readJpegCamera(Uint8List bytes) {
  final segment = _exifPayload(bytes);
  if (segment == null) return (make: '', model: '', orientation: 1);
  final make = _asciiTag(segment, 0x010F);
  final model = _asciiTag(segment, 0x0110);
  return (make: make, model: model, orientation: _orientationOf(bytes));
}

Uint8List _exifSegment({
  required String make,
  required String model,
  required DateTime when,
  required int orientation,
}) {
  final makeBytes = _ascii(make, 32);
  final modelBytes = _ascii(model, 64);
  final whenBytes = _ascii(_exifTime(when), 20);
  // TIFF header (8) + IFD0 (2 + 5*12 + 4) = 74. Short text stays inside its entry.
  const data = 74;
  var cursor = data;
  int place(Uint8List blob) {
    if (blob.length <= 4) {
      var inline = 0;
      for (var i = 0; i < blob.length; i++) {
        inline |= blob[i] << (8 * i);
      }
      return inline;
    }
    final at = cursor;
    cursor += blob.length;
    return at;
  }

  final makeAt = place(makeBytes);
  final modelAt = place(modelBytes);
  final whenAt = place(whenBytes);
  final exifAt = cursor;
  final body = BytesBuilder(copy: false);
  body.add(const [0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00]);
  _u16(body, 5);
  _entry(body, 0x010F, 2, makeBytes.length, makeAt);
  _entry(body, 0x0110, 2, modelBytes.length, modelAt);
  _entry(body, 0x0112, 3, 1, orientation & 0xFFFF);
  _entry(body, 0x0132, 2, whenBytes.length, whenAt);
  _entry(body, 0x8769, 4, 1, exifAt);
  _u32(body, 0);
  if (makeBytes.length > 4) body.add(makeBytes);
  if (modelBytes.length > 4) body.add(modelBytes);
  if (whenBytes.length > 4) body.add(whenBytes);
  _u16(body, 3);
  _entry(body, 0x9003, 2, whenBytes.length, whenAt);
  _entry(body, 0x9004, 2, whenBytes.length, whenAt);
  _entry(body, 0x9291, 2, 4, 0x00303030); // "000\0" inline, little-endian
  _u32(body, 0);
  final tiff = body.toBytes();
  final payload = BytesBuilder(copy: false);
  payload.add('Exif\x00\x00'.codeUnits);
  payload.add(tiff);
  final raw = payload.toBytes();
  final segment = BytesBuilder(copy: false);
  segment.add(const [0xFF, 0xE1]);
  _u16be(segment, raw.length + 2);
  segment.add(raw);
  return segment.toBytes();
}

void _entry(BytesBuilder body, int tag, int type, int count, int value) {
  _u16(body, tag);
  _u16(body, type);
  _u32(body, count);
  _u32(body, value);
}

void _u16(BytesBuilder body, int value) => body.add([value & 0xFF, (value >> 8) & 0xFF]);

void _u16be(BytesBuilder body, int value) => body.add([(value >> 8) & 0xFF, value & 0xFF]);

void _u32(BytesBuilder body, int value) {
  body.add([
    value & 0xFF,
    (value >> 8) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 24) & 0xFF,
  ]);
}

Uint8List _ascii(String value, int maxChars) {
  final clean = value.replaceAll(RegExp(r'[^\x20-\x7E]'), ' ').trim();
  final text = (clean.isEmpty ? 'device' : clean);
  final cut = text.length > maxChars ? text.substring(0, maxChars) : text;
  return Uint8List.fromList([...cut.codeUnits, 0]);
}

String _exifTime(DateTime when) {
  final local = when.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year.toString().padLeft(4, '0')}:${two(local.month)}:${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

int _orientationOf(Uint8List bytes) {
  final segment = _exifPayload(bytes);
  if (segment == null || segment.length < 8) return 1;
  final little = segment[0] == 0x49 && segment[1] == 0x49;
  final big = segment[0] == 0x4D && segment[1] == 0x4D;
  if (!little && !big) return 1;
  int u16(int offset) {
    if (offset < 0 || offset + 2 > segment.length) return -1;
    return little
        ? segment[offset] | (segment[offset + 1] << 8)
        : (segment[offset] << 8) | segment[offset + 1];
  }

  int u32(int offset) {
    if (offset < 0 || offset + 4 > segment.length) return -1;
    return little
        ? segment[offset] |
            (segment[offset + 1] << 8) |
            (segment[offset + 2] << 16) |
            (segment[offset + 3] << 24)
        : (segment[offset] << 24) |
            (segment[offset + 1] << 16) |
            (segment[offset + 2] << 8) |
            segment[offset + 3];
  }

  final ifd = u32(4);
  if (ifd < 0 || ifd + 2 > segment.length) return 1;
  final count = u16(ifd);
  for (var n = 0; n < count; n++) {
    final entry = ifd + 2 + n * 12;
    if (entry + 12 > segment.length) return 1;
    if (u16(entry) != 0x0112) continue;
    final value = u16(entry + 8);
    if (value < 1 || value > 8) return 1;
    return value;
  }
  return 1;
}

Uint8List? _exifPayload(Uint8List bytes) {
  var i = 2;
  while (i + 3 < bytes.length && bytes[i] == 0xFF) {
    final marker = bytes[i + 1];
    if (marker == 0xDA || marker == 0xD9) return null;
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
      i += 2;
      continue;
    }
    final length = (bytes[i + 2] << 8) | bytes[i + 3];
    if (length < 2 || i + 2 + length > bytes.length) return null;
    if (marker == 0xE1 && _isExif(bytes, i + 4, length - 2)) {
      return bytes.sublist(i + 10, i + 2 + length);
    }
    i += 2 + length;
  }
  return null;
}

bool _isExif(Uint8List bytes, int start, int count) {
  const sig = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00];
  if (count < sig.length || start + sig.length > bytes.length) return false;
  for (var n = 0; n < sig.length; n++) {
    if (bytes[start + n] != sig[n]) return false;
  }
  return true;
}

bool _isXmp(Uint8List bytes, int start, int count) {
  const sig = 'http://ns.adobe.com/xap/1.0/';
  if (count < sig.length || start + sig.length > bytes.length) return false;
  for (var n = 0; n < sig.length; n++) {
    if (bytes[start + n] != sig.codeUnitAt(n)) return false;
  }
  return true;
}

String _asciiTag(Uint8List tiff, int tag) => _value(tiff, tag, ascii: true) ?? '';

/// Reads one IFD0 ASCII tag.
String? _value(Uint8List tiff, int tag, {required bool ascii}) {
  if (tiff.length < 10 || tiff[0] != 0x49 || tiff[1] != 0x49) return null;
  final ifd = _u32at(tiff, 4);
  if (ifd < 0 || ifd + 2 > tiff.length) return null;
  final count = tiff[ifd] | (tiff[ifd + 1] << 8);
  for (var n = 0; n < count; n++) {
    final entry = ifd + 2 + n * 12;
    if (entry + 12 > tiff.length) return null;
    final found = tiff[entry] | (tiff[entry + 1] << 8);
    if (found != tag) continue;
    final type = tiff[entry + 2] | (tiff[entry + 3] << 8);
    final nvals = _u32at(tiff, entry + 4);
    final inline = _u32at(tiff, entry + 8);
    if (!ascii) {
      return String.fromCharCodes([inline & 0xFF, (inline >> 8) & 0xFF]);
    }
    if (type != 2 || nvals <= 0) return null;
    final offset = nvals <= 4 ? entry + 8 : inline;
    if (offset < 0 || offset + nvals > tiff.length) return null;
    final chars = tiff.sublist(offset, offset + nvals);
    final end = chars.indexOf(0);
    return String.fromCharCodes(end < 0 ? chars : chars.sublist(0, end));
  }
  return null;
}

int _u32at(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 4 > bytes.length) return -1;
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}
