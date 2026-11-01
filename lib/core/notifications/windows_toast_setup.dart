import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

/// The id Windows uses to decide this app may show a toast.
const windowsNotificationAppId = 'com.socialsave.SocialSave';

/// Icon path stored with that id. Empty when this is not the Windows app.
String? windowsNotificationIconPath() {
  if (!Platform.isWindows) return null;
  final exe = Platform.resolvedExecutable;
  return exe.isEmpty ? null : exe;
}

/// Windows hides toasts from an unpackaged app until a Start menu shortcut
/// carries [windowsNotificationAppId].
void ensureWindowsNotificationIdentity() {
  if (!Platform.isWindows) return;
  try {
    _setProcessAppId();
    _writeShortcut();
  } catch (_) {}
}

void _setProcessAppId() {
  final shell = DynamicLibrary.open('shell32.dll');
  final setId = shell.lookupFunction<
    Int32 Function(Pointer<Utf16>),
    int Function(Pointer<Utf16>)
  >('SetCurrentProcessExplicitAppUserModelID');
  final id = windowsNotificationAppId.toNativeUtf16();
  try {
    setId(id);
  } finally {
    calloc.free(id);
  }
}

void _writeShortcut() {
  final appData = Platform.environment['APPDATA'];
  final exe = Platform.resolvedExecutable;
  if (appData == null || appData.isEmpty || exe.isEmpty) return;
  final linkPath = p.join(
    appData,
    'Microsoft',
    'Windows',
    'Start Menu',
    'Programs',
    'SocialSave.lnk',
  );
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  final link = ShellLink.createInstance();
  final exePtr = exe.toNativeUtf16();
  final dirPtr = p.dirname(exe).toNativeUtf16();
  final descPtr = 'Social Save'.toNativeUtf16();
  final linkPtr = linkPath.toNativeUtf16();
  final idPtr = windowsNotificationAppId.toNativeUtf16();
  final key = calloc<PROPERTYKEY>();
  final value = calloc<PROPVARIANT>();
  IPropertyStore? store;
  IPersistFile? file;
  try {
    link.setPath(exePtr);
    link.setWorkingDirectory(dirPtr);
    link.setDescription(descPtr);
    link.setIconLocation(exePtr, 0);
    key.ref.fmtid.setGUID('{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}');
    key.ref.pid = 5;
    PropVariantInit(value);
    value.ref.vt = VT_LPWSTR;
    value.ref.pwszVal = idPtr;
    store = IPropertyStore.from(link);
    if (store.setValue(key, value) != 0) return;
    if (store.commit() != 0) return;
    file = IPersistFile.from(link);
    file.save(linkPtr, 1);
  } finally {
    file?.release();
    store?.release();
    link.release();
    calloc.free(exePtr);
    calloc.free(dirPtr);
    calloc.free(descPtr);
    calloc.free(linkPtr);
    calloc.free(idPtr);
    calloc.free(key);
    calloc.free(value);
  }
}
