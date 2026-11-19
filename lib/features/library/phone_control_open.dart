import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

int Function(Pointer<Void>, int, Pointer<Utf16>)? _createMutex;

int _createControlMutex(Pointer<Utf16> name) {
  final create = _createMutex ??= DynamicLibrary.open('kernel32.dll').lookupFunction<
      IntPtr Function(Pointer<Void> attrs, Int32 owner, Pointer<Utf16> name),
      int Function(Pointer<Void> attrs, int owner, Pointer<Utf16> name)>('CreateMutexW');
  return create(nullptr, 1, name);
}

/// Native title of the phone-control window, and the argument that opens it.
const phoneControlWindowTitle = 'Control the phone';
const phoneControlArgument = '--phone-control';

int _controlMutex = 0;

/// True when this process owns the control window. A second launch loses.
bool claimPhoneControlWindow() {
  if (!Platform.isWindows) return false;
  final name = 'Local\\SocialSavePhoneControl'.toNativeUtf16();
  try {
    _controlMutex = _createControlMutex(name);
    if (_controlMutex == 0) return true;
    return GetLastError() != ERROR_ALREADY_EXISTS;
  } catch (_) {
    return true;
  } finally {
    calloc.free(name);
  }
}

/// Brings an existing control window forward. False when none is open.
bool focusPhoneControlWindow() {
  if (!Platform.isWindows) return false;
  try {
    final hwnd = _findControlWindow();
    if (hwnd == 0) return false;
    ShowWindow(hwnd, SW_RESTORE);
    final fg = GetForegroundWindow();
    if (fg != 0 && fg != hwnd) {
      final from = GetWindowThreadProcessId(fg, nullptr);
      final to = GetWindowThreadProcessId(hwnd, nullptr);
      AttachThreadInput(from, to, 1);
      SetForegroundWindow(hwnd);
      BringWindowToTop(hwnd);
      AttachThreadInput(from, to, 0);
    } else {
      SetForegroundWindow(hwnd);
      BringWindowToTop(hwnd);
    }
    return true;
  } catch (_) {
    return false;
  }
}

int _findControlWindow() {
  final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
  final title = phoneControlWindowTitle.toNativeUtf16();
  try {
    return FindWindow(cls, title);
  } finally {
    calloc.free(cls);
    calloc.free(title);
  }
}

/// Opens the control window, or focuses it when it is already open.
Future<bool> openPhoneControlWindow() async {
  if (!Platform.isWindows) return false;
  if (focusPhoneControlWindow()) return true;
  try {
    AllowSetForegroundWindow(0xFFFFFFFF);
    await Process.start(
      Platform.resolvedExecutable,
      const [phoneControlArgument],
      mode: ProcessStartMode.detached,
    );
    return true;
  } catch (_) {
    return false;
  }
}
