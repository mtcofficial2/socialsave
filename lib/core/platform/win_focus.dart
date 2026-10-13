import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Windows: gives keyboard focus back to this app's Flutter view. Needed
/// after the window style changes for full screen, which can leave the
/// Win32 focus on nothing, so key presses never reach Flutter.
class WinFocus {
  WinFocus._();

  /// Top-level SocialSave window of *this* process (not another copy).
  static int _ownWindow() {
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final pid = calloc<Uint32>();
    try {
      final me = GetCurrentProcessId();
      var h = 0;
      while (true) {
        h = FindWindowEx(0, h, cls, nullptr);
        if (h == 0) return 0;
        GetWindowThreadProcessId(h, pid);
        if (pid.value == me) return h;
      }
    } finally {
      calloc.free(cls);
      calloc.free(pid);
    }
  }

  static void focusSelf() {
    if (!Platform.isWindows) return;
    try {
      final top = _ownWindow();
      if (top == 0) return;
      final viewCls = 'FLUTTERVIEW'.toNativeUtf16();
      final view = FindWindowEx(top, 0, viewCls, nullptr);
      calloc.free(viewCls);
      // Only switch foreground if we already are the foreground app (full
      // screen was toggled by the user here); never steal from other apps.
      final fg = GetForegroundWindow();
      final pid = calloc<Uint32>();
      GetWindowThreadProcessId(fg, pid);
      final ours = pid.value == GetCurrentProcessId();
      calloc.free(pid);
      if (ours || fg == 0) {
        SetForegroundWindow(top);
        BringWindowToTop(top);
      }
      if (view != 0) SetFocus(view);
    } catch (_) {}
  }
}
