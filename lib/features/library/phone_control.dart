import 'dart:math' as math;
import 'dart:typed_data';

/// One app the computer can open on the plugged-in phone.
class PhoneControlApp {
  const PhoneControlApp({required this.name, required this.packageName, required this.system});

  final String name;
  final String packageName;
  final bool system;
}

/// True for a normal Android package name. Anything else is not launched.
bool phoneControlPackage(String packageName) {
  return RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$').hasMatch(packageName);
}

/// The list the phone may send over the cable. APK paths and icons stay off it.
List<Map<String, Object>> phoneControlWireApps(List<Map<Object?, Object?>>? raw) {
  final apps = <Map<String, Object>>[];
  for (final row in raw ?? const <Map<Object?, Object?>>[]) {
    final name = '${row['name'] ?? ''}'.trim();
    final packageName = '${row['package'] ?? ''}'.trim();
    if (name.isEmpty || !phoneControlPackage(packageName)) continue;
    apps.add({'name': name, 'package': packageName, 'system': row['system'] == true});
  }
  return apps;
}

/// Apps from the phone's loopback list. Rows without a safe package are dropped.
List<PhoneControlApp> phoneControlApps(Object? raw) {
  if (raw is! Map) return const [];
  final rows = raw['apps'];
  if (rows is! List) return const [];
  final apps = <PhoneControlApp>[];
  for (final row in rows) {
    if (row is! Map) continue;
    final name = '${row['name'] ?? ''}'.trim();
    final packageName = '${row['package'] ?? ''}'.trim();
    if (name.isEmpty || !phoneControlPackage(packageName)) continue;
    apps.add(PhoneControlApp(name: name, packageName: packageName, system: row['system'] == true));
  }
  apps.sort((a, b) {
    if (a.system != b.system) return a.system ? 1 : -1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return apps;
}

/// Width and height from a PNG, or null when the bytes are not a screen shot.
(int, int)? pngSize(List<int> bytes) {
  if (bytes.length < 24) return null;
  if (bytes[0] != 0x89 || bytes[1] != 0x50 || bytes[2] != 0x4e || bytes[3] != 0x47) return null;
  final width = (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
  final height = (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
  if (width <= 0 || height <= 0 || width > 8000 || height > 8000) return null;
  return (width, height);
}

/// Where a click on the fitted screen lands on the phone. Null when the click misses the picture.
({int x, int y})? phoneControlTap({
  required double localX,
  required double localY,
  required double boxW,
  required double boxH,
  required int imageW,
  required int imageH,
}) {
  if (boxW <= 0 || boxH <= 0 || imageW <= 0 || imageH <= 0) return null;
  final scale = math.min(boxW / imageW, boxH / imageH);
  final destW = imageW * scale;
  final destH = imageH * scale;
  final dx = (boxW - destW) / 2;
  final dy = (boxH - destH) / 2;
  final x = (localX - dx) / destW;
  final y = (localY - dy) / destH;
  if (x < 0 || y < 0 || x > 1 || y > 1) return null;
  return (x: (x * imageW).round().clamp(0, imageW - 1), y: (y * imageH).round().clamp(0, imageH - 1));
}

/// The words sent to the phone. Empty when there is nothing safe to type.
String phoneControlType(String raw) {
  final clean = raw.replaceAll(RegExp(r'[\u0000-\u001f]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.isEmpty) return '';
  return clean.length > 200 ? clean.substring(0, 200) : clean;
}

/// True when a search box should keep this app.
bool phoneControlMatches(PhoneControlApp app, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return app.name.toLowerCase().contains(q) || app.packageName.toLowerCase().contains(q);
}

/// One shell word, so the phone's shell cannot split the text or run it.
String phoneControlShellQuote(String text) {
  return "'${text.replaceAll("'", r"'\''")}'";
}

/// PNG bytes are a screen shot when the header and size agree.
bool phoneControlShot(Uint8List bytes) => pngSize(bytes) != null;
