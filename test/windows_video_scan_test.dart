import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:social_save/core/platform/windows_video_scan.dart';

void main() {
  test('a computer video search skips junk and reuses unchanged folders', () async {
    if (!Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('ss-scan-');
    final bytes = List<int>.filled(100 * 1024 + 8, 7);
    try {
      await File(p.join(root.path, 'keep.mp4')).writeAsBytes(bytes);
      await File(p.join(root.path, 'note.txt')).writeAsString('hello');
      final clips = Directory(p.join(root.path, 'clips'))..createSync();
      await File(p.join(clips.path, 'clip.mkv')).writeAsBytes(bytes);
      final modules = Directory(p.join(root.path, 'node_modules'))..createSync();
      await File(p.join(modules.path, 'secret.mp4')).writeAsBytes(bytes);

      final first = scanWindowsVideoRoot(root.path);
      final titles = first.videos.map((video) => video['title']).toSet();
      expect(titles, {'keep', 'clip'});

      final second = scanWindowsVideoRoot(root.path, first.dirs);
      expect(second.videos.map((video) => video['title']).toSet(), titles);

      await File(p.join(root.path, 'new.webm')).writeAsBytes(bytes);
      final third = scanWindowsVideoRoot(root.path, second.dirs);
      expect(third.videos.map((video) => video['title']), contains('new'));
    } finally {
      if (root.existsSync()) await root.delete(recursive: true);
    }
  });
}
