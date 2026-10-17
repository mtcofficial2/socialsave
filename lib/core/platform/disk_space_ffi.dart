import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win32;

/// Windows: (free, total) bytes of the drive holding [path], or null.
(int, int)? windowsDiskSpace(String path) {
  final p = path.toNativeUtf16();
  final free = calloc<Uint64>();
  final total = calloc<Uint64>();
  final totalFree = calloc<Uint64>();
  try {
    final ok = win32.GetDiskFreeSpaceEx(p, free, total, totalFree);
    if (ok == 0) return null;
    return (free.value, total.value);
  } finally {
    calloc.free(p);
    calloc.free(free);
    calloc.free(total);
    calloc.free(totalFree);
  }
}
