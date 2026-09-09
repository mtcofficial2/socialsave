import 'package:path/path.dart' as p;
import 'package:social_save/core/constants/app_constants.dart';

class FileUtils {
  const FileUtils();

  String sanitizeFileName(String input) {
    final cleaned = input
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) {
      return 'video';
    }
    return cleaned.length > 80 ? cleaned.substring(0, 80).trim() : cleaned;
  }

  String extensionFor(String format, {String fallback = 'mp4'}) {
    final normalized = format.toLowerCase().replaceAll('.', '');
    if (AppConstants.allowedVideoExtensions.contains(normalized)) {
      return normalized;
    }
    return fallback;
  }

  String uniquePath(String directory, String fileName) {
    final ext = p.extension(fileName);
    final stem = p.basenameWithoutExtension(fileName);
    var candidate = p.join(directory, fileName);
    var index = 1;
    while (true) {
      // Existence is checked by the caller with dart:io File.
      if (index == 1) {
        return candidate;
      }
      candidate = p.join(directory, '$stem ($index)$ext');
      index++;
      if (index > 1000) {
        return p.join(directory, '$stem-${DateTime.now().millisecondsSinceEpoch}$ext');
      }
    }
  }

  String buildFileName({
    required String title,
    required String format,
    String? quality,
  }) {
    final stem = sanitizeFileName(title);
    final ext = extensionFor(format);
    if (quality == null || quality.isEmpty || quality.toLowerCase() == 'original') {
      return '$stem.$ext';
    }
    return '$stem-$quality.$ext';
  }
}
