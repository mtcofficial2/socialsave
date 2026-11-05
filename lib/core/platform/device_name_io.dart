import 'dart:io';

import 'package:flutter/services.dart';

/// Maker and model, or the operating system on a computer. Not a serial.
Future<String> appDeviceModel() async {
  if (Platform.isAndroid) {
    try {
      final model = await const MethodChannel(
        'socialsave/media',
      ).invokeMethod<String>('deviceModel');
      return model?.trim() ?? '';
    } catch (_) {}
    return '';
  }
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    final version = Platform.operatingSystemVersion.trim();
    if (version.isEmpty) return '';
    return version.length <= 40 ? version : version.substring(0, 40);
  }
  return '';
}

/// The name of this phone or computer. This is not a serial number.
Future<String> appDeviceName() async {
  if (Platform.isAndroid) {
    try {
      final name = await const MethodChannel(
        'socialsave/media',
      ).invokeMethod<String>('deviceName');
      final trimmed = name?.trim() ?? '';
      if (trimmed.isNotEmpty) return trimmed;
    } catch (_) {}
    return 'Android phone';
  }
  if (Platform.isWindows) {
    final name =
        Platform.environment['COMPUTERNAME'] ?? Platform.localHostname;
    final trimmed = name.trim();
    return trimmed.isEmpty ? 'Windows computer' : trimmed;
  }
  if (Platform.isIOS) return 'iPhone';
  if (Platform.isMacOS) {
    final name = Platform.localHostname.trim();
    return name.isEmpty ? 'Mac' : name;
  }
  if (Platform.isLinux) {
    final name = Platform.localHostname.trim();
    return name.isEmpty ? 'Linux computer' : name;
  }
  return 'This device';
}
