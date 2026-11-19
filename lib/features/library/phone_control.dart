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

/// Where a point on the fitted screen lands on the phone.
///
/// Null when the point misses the picture. [clamp] keeps a drag that slides
/// off the picture and pins it to the edge.
({int x, int y})? phoneControlPoint({
  required double localX,
  required double localY,
  required double boxW,
  required double boxH,
  required int imageW,
  required int imageH,
  bool clamp = false,
}) {
  if (boxW <= 0 || boxH <= 0 || imageW <= 0 || imageH <= 0) return null;
  final scale = math.min(boxW / imageW, boxH / imageH);
  final destW = imageW * scale;
  final destH = imageH * scale;
  final dx = (boxW - destW) / 2;
  final dy = (boxH - destH) / 2;
  var x = (localX - dx) / destW;
  var y = (localY - dy) / destH;
  final outside = x < 0 || y < 0 || x > 1 || y > 1;
  if (outside && !clamp) return null;
  if (outside) {
    x = x.clamp(0.0, 1.0);
    y = y.clamp(0.0, 1.0);
  }
  return (x: (x * imageW).round().clamp(0, imageW - 1), y: (y * imageH).round().clamp(0, imageH - 1));
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
  return phoneControlPoint(localX: localX, localY: localY, boxW: boxW, boxH: boxH, imageW: imageW, imageH: imageH);
}

/// What the finger did on the phone picture.
enum PhoneMotion { tap, hold, swipe }

/// A tap, a hold, or a swipe in phone pixels.
class PhoneMotionEvent {
  const PhoneMotionEvent({
    required this.motion,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.ms,
  });

  final PhoneMotion motion;
  final int x1;
  final int y1;
  final int x2;
  final int y2;
  final int ms;
}

/// A press on the fitted picture. A short still press is a tap, a long still
/// press is a hold, and a drag is a swipe. Null when the press starts off the picture.
PhoneMotionEvent? phoneControlMotion({
  required double downX,
  required double downY,
  required double upX,
  required double upY,
  required int elapsedMs,
  required double boxW,
  required double boxH,
  required int imageW,
  required int imageH,
}) {
  final start = phoneControlPoint(localX: downX, localY: downY, boxW: boxW, boxH: boxH, imageW: imageW, imageH: imageH);
  if (start == null) return null;
  final end = phoneControlPoint(localX: upX, localY: upY, boxW: boxW, boxH: boxH, imageW: imageW, imageH: imageH, clamp: true);
  if (end == null) return null;
  final distance = math.sqrt(math.pow(end.x - start.x, 2) + math.pow(end.y - start.y, 2));
  final slop = math.max(18.0, imageW * 0.02);
  if (distance >= slop) {
    return PhoneMotionEvent(
      motion: PhoneMotion.swipe,
      x1: start.x,
      y1: start.y,
      x2: end.x,
      y2: end.y,
      ms: elapsedMs.clamp(50, 1200),
    );
  }
  if (elapsedMs >= 420) {
    return PhoneMotionEvent(motion: PhoneMotion.hold, x1: start.x, y1: start.y, x2: start.x, y2: start.y, ms: 560);
  }
  return PhoneMotionEvent(motion: PhoneMotion.tap, x1: start.x, y1: start.y, x2: start.x, y2: start.y, ms: 0);
}

/// A turn of the mouse wheel becomes a short swipe at that spot.
/// Wheel down moves the page down, which is a finger swipe toward the top.
PhoneMotionEvent? phoneControlWheel({
  required double localX,
  required double localY,
  required double boxW,
  required double boxH,
  required int imageW,
  required int imageH,
  required double deltaY,
}) {
  if (deltaY == 0) return null;
  final start = phoneControlPoint(localX: localX, localY: localY, boxW: boxW, boxH: boxH, imageW: imageW, imageH: imageH);
  if (start == null) return null;
  // One mouse notch is about 100. A flick of several notches scrolls further.
  final notches = (deltaY.abs() / 100).clamp(0.35, 4.0);
  final distance = (imageH * 0.16 * notches).round().clamp(80, 900);
  final endY = (start.y + (deltaY > 0 ? -distance : distance)).clamp(0, imageH - 1);
  if (endY == start.y) return null;
  return PhoneMotionEvent(motion: PhoneMotion.swipe, x1: start.x, y1: start.y, x2: start.x, y2: endY, ms: 220);
}

/// One computer key that can be sent to the phone.
enum PhoneKeyKind { back, enter, backspace, delete, up, down, left, right, tab, volumeUp, volumeDown, character }

class PhoneKeyPress {
  const PhoneKeyPress(this.kind, [this.text = '']);

  final PhoneKeyKind kind;
  final String text;
}

/// A key pressed while the phone picture is focused. Null for shortcuts and keys we do not send.
PhoneKeyPress? phoneControlKey({required String? name, required String character, bool shortcut = false}) {
  if (shortcut) return null;
  switch (name) {
    case 'Escape':
      return const PhoneKeyPress(PhoneKeyKind.back);
    case 'Enter':
    case 'Numpad Enter':
      return const PhoneKeyPress(PhoneKeyKind.enter);
    case 'Backspace':
      return const PhoneKeyPress(PhoneKeyKind.backspace);
    case 'Delete':
      return const PhoneKeyPress(PhoneKeyKind.delete);
    case 'Arrow Up':
      return const PhoneKeyPress(PhoneKeyKind.up);
    case 'Arrow Down':
      return const PhoneKeyPress(PhoneKeyKind.down);
    case 'Arrow Left':
      return const PhoneKeyPress(PhoneKeyKind.left);
    case 'Arrow Right':
      return const PhoneKeyPress(PhoneKeyKind.right);
    case 'Tab':
      return const PhoneKeyPress(PhoneKeyKind.tab);
    case 'Audio Volume Up':
      return const PhoneKeyPress(PhoneKeyKind.volumeUp);
    case 'Audio Volume Down':
      return const PhoneKeyPress(PhoneKeyKind.volumeDown);
  }
  final text = phoneControlChar(character);
  if (text.isEmpty) return null;
  return PhoneKeyPress(PhoneKeyKind.character, text);
}

/// One typed character. A space is kept. Control characters are dropped.
String phoneControlChar(String raw) {
  if (raw.runes.length != 1) return '';
  final code = raw.runes.single;
  if (code < 32 || code == 127) return '';
  return raw;
}

/// Several keys typed in a row. Spaces stay. Control characters are dropped.
String phoneControlBurst(String raw) {
  final codes = <int>[];
  for (final code in raw.runes) {
    if (code < 32 || code == 127) continue;
    codes.add(code);
    if (codes.length >= 200) break;
  }
  return String.fromCharCodes(codes);
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
