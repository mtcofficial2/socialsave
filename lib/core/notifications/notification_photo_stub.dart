import 'dart:typed_data';

/// The browser build has no notification photo file.
Future<void> storeNotificationPhoto(String name, int rev, Uint8List bytes) async {}

Future<({Uint8List? bytes, bool exact})> loadNotificationPhoto(
  String name,
  int rev,
) async => (bytes: null, exact: false);

Future<String?> saveNotificationPhoto(Uint8List bytes, String name) async {
  return null;
}
