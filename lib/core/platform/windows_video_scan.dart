// Windows-only helpers for the Library: video scanning and shell thumbnails.
// Everything here runs inside background isolates (see DesktopSupport).
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart' as w;

const windowsVideoExtensions = {
  'mp4', 'mkv', 'webm', 'mov', 'avi', 'm4v', '3gp', 'wmv', 'flv', 'ts',
};

const _skipDirs = {
  'node_modules', 'build', '.git', 'appdata', '\$recycle.bin',
  'system volume information', 'my music', 'my pictures', 'my videos',
};

const _minBytes = 100 * 1024;
const _hidden = 0x2;
const _system = 0x4;
const _reparse = 0x400;
const _driveFixed = 3;

/// The default folders, plus `X:\Videos` on other fixed drives.
List<String> windowsDefaultVideoRoots() {
  final home = Platform.environment['USERPROFILE'] ?? r'C:\Users\Public';
  final roots = <String>[
    p.join(home, 'Videos'),
    p.join(home, 'Downloads'),
    p.join(home, 'Desktop'),
    p.join(home, 'Documents'),
    p.join(home, 'OneDrive', 'Videos'),
  ];
  final systemDrive = (Platform.environment['SystemDrive'] ?? 'C:').toUpperCase();
  try {
    final mask = w.GetLogicalDrives();
    for (var i = 2; i < 26; i++) {
      if (mask & (1 << i) == 0) continue;
      final letter = '${String.fromCharCode(65 + i)}:';
      if (letter == systemDrive) continue;
      final root = '$letter\\'.toNativeUtf16();
      final type = w.GetDriveType(root);
      calloc.free(root);
      if (type != _driveFixed) continue;
      roots.add('$letter\\Videos');
    }
  } catch (_) {}
  return roots.where((dir) => Directory(dir).existsSync()).toList();
}

int _attributes(String path) {
  final native = path.toNativeUtf16();
  try {
    return w.GetFileAttributes(native) & 0xFFFFFFFF;
  } finally {
    calloc.free(native);
  }
}

bool _skipDirectory(String path) {
  final name = p.basename(path).toLowerCase();
  if (name.startsWith('.') || name.startsWith('\$') || _skipDirs.contains(name)) {
    return true;
  }
  final attrs = _attributes(path);
  if (attrs == 0xFFFFFFFF) return true;
  return attrs & (_hidden | _system | _reparse) != 0;
}

/// Scans one root folder recursively. Returns the same map shape as the
/// Android `listVideos` call, plus a `folder` entry.
List<Map<String, Object?>> scanWindowsVideoRoot(String root) {
  final out = <Map<String, Object?>>[];
  final pending = <String>[root];
  while (pending.isNotEmpty) {
    final dir = pending.removeLast();
    List<FileSystemEntity> entries;
    try {
      entries = Directory(dir).listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final entity in entries) {
      if (entity is Directory) {
        if (!_skipDirectory(entity.path)) pending.add(entity.path);
        continue;
      }
      if (entity is! File) continue;
      final ext = p.extension(entity.path).replaceAll('.', '').toLowerCase();
      if (!windowsVideoExtensions.contains(ext)) continue;
      try {
        final stat = entity.statSync();
        if (stat.size < _minBytes) continue;
        out.add({
          'id': entity.path,
          'title': p.basenameWithoutExtension(entity.path),
          'path': entity.path,
          'uri': null,
          'durationMs': 0,
          'size': stat.size,
          'addedAt': stat.modified.millisecondsSinceEpoch,
          'folder': p.dirname(entity.path),
        });
      } catch (_) {}
    }
  }
  return out;
}

/// Asks the Windows shell (Explorer's thumbnail cache) for a frame of the
/// video and writes it as a BMP. Returns null when Windows has no thumbnail.
String? windowsShellThumbnail(String path, String outPath, int size) {
  final hrInit = w.CoInitializeEx(nullptr, w.COINIT_APARTMENTTHREADED);
  final pathPtr = path.toNativeUtf16();
  final riid = w.convertToIID(w.IID_IShellItemImageFactory);
  final ppv = calloc<Pointer>();
  final sizePtr = calloc<w.SIZE>();
  final hbmPtr = calloc<IntPtr>();
  final bmp = calloc<w.BITMAP>();
  final info = calloc<w.BITMAPINFO>();
  var hdc = 0;
  try {
    final hr = w.SHCreateItemFromParsingName(pathPtr, nullptr, riid, ppv);
    if (w.FAILED(hr) || ppv.value == nullptr) return null;
    final factory = w.IShellItemImageFactory(ppv.cast());
    sizePtr.ref
      ..cx = size
      ..cy = size;
    final hr2 = factory.getImage(
      sizePtr.ref,
      // Real frames only; without one the app keeps its placeholder.
      w.SIIGBF_BIGGERSIZEOK | w.SIIGBF_THUMBNAILONLY,
      hbmPtr,
    );
    factory.release();
    if (w.FAILED(hr2) || hbmPtr.value == 0) return null;
    final hbm = hbmPtr.value;
    try {
      if (w.GetObject(hbm, sizeOf<w.BITMAP>(), bmp) == 0) return null;
      final width = bmp.ref.bmWidth;
      final height = bmp.ref.bmHeight.abs();
      if (width <= 0 || height <= 0) return null;
      info.ref.bmiHeader
        ..biSize = sizeOf<w.BITMAPINFOHEADER>()
        ..biWidth = width
        ..biHeight = -height
        ..biPlanes = 1
        ..biBitCount = 32
        ..biCompression = 0;
      final stride = width * 4;
      final pixels = calloc<Uint8>(stride * height);
      try {
        hdc = w.CreateCompatibleDC(0);
        final lines = w.GetDIBits(hdc, hbm, 0, height, pixels, info, 0);
        if (lines == 0) return null;
        final data = Uint8List.fromList(pixels.asTypedList(stride * height));
        for (var i = 3; i < data.length; i += 4) {
          data[i] = 255;
        }
        File(outPath).writeAsBytesSync(_bmpFile(width, height, data), flush: true);
        return outPath;
      } finally {
        calloc.free(pixels);
      }
    } finally {
      w.DeleteObject(hbm);
    }
  } catch (_) {
    return null;
  } finally {
    if (hdc != 0) w.DeleteDC(hdc);
    calloc.free(pathPtr);
    calloc.free(riid);
    calloc.free(ppv);
    calloc.free(sizePtr);
    calloc.free(hbmPtr);
    calloc.free(bmp);
    calloc.free(info);
    if (w.SUCCEEDED(hrInit)) w.CoUninitialize();
  }
}

/// 32-bit top-down BMP (BGRA rows, as returned by GetDIBits).
Uint8List _bmpFile(int width, int height, Uint8List bgra) {
  const header = 14 + 40;
  final bytes = ByteData(header + bgra.length);
  bytes
    ..setUint8(0, 0x42)
    ..setUint8(1, 0x4D)
    ..setUint32(2, header + bgra.length, Endian.little)
    ..setUint32(10, header, Endian.little)
    ..setUint32(14, 40, Endian.little)
    ..setInt32(18, width, Endian.little)
    ..setInt32(22, -height, Endian.little)
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, 32, Endian.little)
    ..setUint32(30, 0, Endian.little)
    ..setUint32(34, bgra.length, Endian.little);
  final out = bytes.buffer.asUint8List();
  out.setRange(header, out.length, bgra);
  return out;
}
