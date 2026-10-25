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
  '.dart_tool', '.gradle', '.idea', '.vs', '__pycache__', '.venv', 'venv',
  'site-packages', 'bower_components', 'pods',
};

const _minBytes = 100 * 1024;
const _hidden = 0x2;
const _system = 0x4;
const _reparse = 0x400;
const _directory = 0x10;
const _driveFixed = 3;
const _fileTimeEpoch = 116444736000000000;

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

int _fileTicks(w.FILETIME time) {
  final low = time.dwLowDateTime.toUnsigned(32);
  final high = time.dwHighDateTime.toUnsigned(32);
  return (high << 32) | low;
}

int _ticksToMillis(int ticks) {
  if (ticks < _fileTimeEpoch) return 0;
  return (ticks - _fileTimeEpoch) ~/ 10000;
}

/// Last-write time of [path] in Windows FILETIME ticks, or 0.
int _dirTicks(String path) {
  final native = path.toNativeUtf16();
  final data = calloc<w.WIN32_FILE_ATTRIBUTE_DATA>();
  try {
    if (w.GetFileAttributesEx(native, w.GetFileExInfoStandard, data) == 0) return 0;
    return _fileTicks(data.ref.ftLastWriteTime);
  } finally {
    calloc.free(native);
    calloc.free(data);
  }
}

bool _skipDirectoryName(String name, int attrs) {
  final lower = name.toLowerCase();
  if (lower == '.' || lower == '..') return true;
  if (lower.startsWith('.') || lower.startsWith('\$') || _skipDirs.contains(lower)) return true;
  return (attrs & (_hidden | _system | _reparse)) != 0;
}

Map<String, Object?>? _asDir(Object? raw) {
  if (raw is! Map) return null;
  return Map<String, Object?>.from(raw.map((key, value) => MapEntry('$key', value)));
}

/// One folder via FindFirstFileEx. Size and time come from the listing,
/// so each video does not need its own stat.
({int before, int after, List<Map<String, Object?>> videos, List<String> children}) _listDir(String dir) {
  final videos = <Map<String, Object?>>[];
  final children = <String>[];
  final before = _dirTicks(dir);
  final pattern = p.join(dir, '*').toNativeUtf16();
  final data = calloc<w.WIN32_FIND_DATA>();
  final handle = w.FindFirstFileEx(
    pattern,
    w.FindExInfoBasic,
    data,
    w.FindExSearchNameMatch,
    nullptr,
    w.FIND_FIRST_EX_LARGE_FETCH,
  );
  calloc.free(pattern);
  if (handle == w.INVALID_HANDLE_VALUE) {
    calloc.free(data);
    return (before: before, after: before, videos: videos, children: children);
  }
  try {
    while (true) {
      final name = data.ref.cFileName;
      final attrs = data.ref.dwFileAttributes;
      final isDir = (attrs & _directory) != 0;
      if (isDir) {
        if (!_skipDirectoryName(name, attrs)) children.add(p.join(dir, name));
      } else if (name != '.' && name != '..') {
        final ext = p.extension(name).replaceAll('.', '').toLowerCase();
        if (windowsVideoExtensions.contains(ext)) {
          final size = (data.ref.nFileSizeHigh.toUnsigned(32) << 32) |
              data.ref.nFileSizeLow.toUnsigned(32);
          if (size >= _minBytes) {
            final child = p.join(dir, name);
            videos.add({
              'id': child,
              'title': p.basenameWithoutExtension(name),
              'path': child,
              'uri': null,
              'durationMs': 0,
              'size': size,
              'addedAt': _ticksToMillis(_fileTicks(data.ref.ftLastWriteTime)),
              'folder': dir,
            });
          }
        }
      }
      if (w.FindNextFile(handle, data) == 0) break;
    }
  } finally {
    w.FindClose(handle);
    calloc.free(data);
  }
  return (before: before, after: _dirTicks(dir), videos: videos, children: children);
}

/// Scans one root. [remembered] is the last index for folders under this root
/// (`m` last-write ticks as a string, `v` videos, `c` child folders). A folder
/// whose time has not changed is reused, so the next search does not walk it.
({List<Map<String, Object?>> videos, Map<String, Object?> dirs}) scanWindowsVideoRoot(
  String root, [
  Map<String, Object?> remembered = const {},
]) {
  final videos = <Map<String, Object?>>[];
  final dirs = <String, Object?>{};
  final pending = <String>[root];
  while (pending.isNotEmpty) {
    final dir = pending.removeLast();
    final cached = _asDir(remembered[dir]);
    final cachedMark = cached == null ? '' : '${cached['m'] ?? ''}';
    final now = cachedMark.isEmpty ? 0 : _dirTicks(dir);
    if (cached != null && cachedMark.isNotEmpty && '$now' == cachedMark) {
      final files = cached['v'];
      if (files is List) {
        for (final raw in files) {
          final item = _asDir(raw);
          if (item != null) videos.add(item);
        }
      }
      final children = cached['c'];
      if (children is List) {
        for (final child in children) {
          final path = '$child';
          if (path.isNotEmpty) pending.add(path);
        }
      }
      dirs[dir] = cached;
      continue;
    }
    final listed = _listDir(dir);
    videos.addAll(listed.videos);
    final stable = listed.before != 0 && listed.before == listed.after;
    dirs[dir] = {
      'm': stable ? '${listed.before}' : '',
      'v': listed.videos,
      'c': listed.children,
    };
    pending.addAll(listed.children);
  }
  return (videos: videos, dirs: dirs);
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
