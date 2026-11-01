import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Writes a sender photo where a Windows toast can read it.
Future<String?> saveNotificationPhoto(Uint8List bytes, String name) async {
  if (bytes.isEmpty) return null;
  final dir = await getTemporaryDirectory();
  final file = File(p.join(dir.path, 'chat-face-${name.hashCode.abs()}.png'));
  await file.writeAsBytes(bytes, flush: true);
  return file.absolute.path;
}
