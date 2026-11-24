import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptNative = Int32 Function(
  Pointer<_DataBlob> dataIn,
  Pointer<Utf16> description,
  Pointer<_DataBlob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  Uint32 flags,
  Pointer<_DataBlob> dataOut,
);
typedef _CryptDart = int Function(
  Pointer<_DataBlob> dataIn,
  Pointer<Utf16> description,
  Pointer<_DataBlob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  int flags,
  Pointer<_DataBlob> dataOut,
);
typedef _UnprotectNative = Int32 Function(
  Pointer<_DataBlob> dataIn,
  Pointer<Pointer<Utf16>> description,
  Pointer<_DataBlob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  Uint32 flags,
  Pointer<_DataBlob> dataOut,
);
typedef _UnprotectDart = int Function(
  Pointer<_DataBlob> dataIn,
  Pointer<Pointer<Utf16>> description,
  Pointer<_DataBlob> entropy,
  Pointer<Void> reserved,
  Pointer<Void> prompt,
  int flags,
  Pointer<_DataBlob> dataOut,
);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);

const _uiForbidden = 0x1;

/// Windows DPAPI (CryptProtectData) for the current user.
class TokenSeal {
  static bool get supported => Platform.isWindows;

  static _CryptDart? _protect;
  static _UnprotectDart? _unprotect;
  static _LocalFreeDart? _free;

  static bool _load() {
    if (_protect != null) return true;
    try {
      final crypt = DynamicLibrary.open('crypt32.dll');
      final kernel = DynamicLibrary.open('kernel32.dll');
      _protect = crypt.lookupFunction<_CryptNative, _CryptDart>('CryptProtectData');
      _unprotect = crypt.lookupFunction<_UnprotectNative, _UnprotectDart>('CryptUnprotectData');
      _free = kernel.lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');
      return true;
    } catch (_) {
      return false;
    }
  }

  static Uint8List? _run(Uint8List input, {required bool seal}) {
    if (!supported || !_load()) return null;
    final dataIn = calloc<_DataBlob>();
    final dataOut = calloc<_DataBlob>();
    final bytes = calloc<Uint8>(input.isEmpty ? 1 : input.length);
    try {
      bytes.asTypedList(input.length).setAll(0, input);
      dataIn.ref
        ..cbData = input.length
        ..pbData = bytes;
      final ok = seal
          ? _protect!(dataIn, nullptr, nullptr, nullptr, nullptr, _uiForbidden, dataOut)
          : _unprotect!(dataIn, nullptr, nullptr, nullptr, nullptr, _uiForbidden, dataOut);
      if (ok == 0 || dataOut.ref.pbData == nullptr) return null;
      final out = Uint8List.fromList(dataOut.ref.pbData.asTypedList(dataOut.ref.cbData));
      _free!(dataOut.ref.pbData.cast());
      return out;
    } catch (_) {
      return null;
    } finally {
      calloc.free(bytes);
      calloc.free(dataIn);
      calloc.free(dataOut);
    }
  }

  /// The sealed form as base64, or null if Windows could not seal it.
  static String? seal(String plain) {
    final out = _run(Uint8List.fromList(utf8.encode(plain)), seal: true);
    return out == null ? null : base64Encode(out);
  }

  static String? unseal(String sealed) {
    try {
      final out = _run(base64Decode(sealed), seal: false);
      return out == null ? null : utf8.decode(out);
    } catch (_) {
      return null;
    }
  }
}
