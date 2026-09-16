import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/utils/file_utils.dart';

enum DownloadLocation { appStorage, publicDownloads }

class DownloadPathService {
  DownloadPathService({FileUtils fileUtils = const FileUtils()})
      : _fileUtils = fileUtils;

  final FileUtils _fileUtils;

  Future<Directory> resolveDirectory(DownloadLocation location) async {
    if (location == DownloadLocation.publicDownloads) {
      final candidates = <Directory>[
        Directory('/storage/emulated/0/Download/${AppConstants.defaultFolderName}'),
        Directory('/sdcard/Download/${AppConstants.defaultFolderName}'),
      ];
      final systemDownloads = await getDownloadsDirectory();
      if (systemDownloads != null) {
        candidates.insert(
          0,
          Directory(p.join(systemDownloads.path, AppConstants.defaultFolderName)),
        );
      }
      for (final folder in candidates) {
        try {
          if (!await folder.exists()) {
            await folder.create(recursive: true);
          }
          final probe = File(p.join(folder.path, '.socialsave_write'));
          await probe.writeAsString('ok');
          await probe.delete();
          return folder;
        } on FileSystemException {
          continue;
        }
      }
    }

    final docs = await getApplicationDocumentsDirectory();
    final folder = Directory(
      p.join(docs.path, AppConstants.defaultFolderName),
    );
    if (!await folder.exists()) {
      await folder.create(recursive: true);
    }
    return folder;
  }

  Future<File> createTargetFile({
    required String title,
    required String format,
    String? quality,
    required DownloadLocation location,
  }) async {
    final directory = await resolveDirectory(location);
    final fileName = _fileUtils.buildFileName(
      title: title,
      format: format,
      quality: quality,
    );
    var file = File(p.join(directory.path, fileName));
    var index = 1;
    while (await file.exists()) {
      final stem = p.basenameWithoutExtension(fileName);
      final ext = p.extension(fileName);
      file = File(p.join(directory.path, '$stem ($index)$ext'));
      index++;
    }
    return file;
  }

  Future<int> cacheSizeBytes() async {
    final temp = await getTemporaryDirectory();
    return _directorySize(temp);
  }

  Future<void> clearCache() async {
    final temp = await getTemporaryDirectory();
    if (await temp.exists()) {
      await for (final entity in temp.list(followLinks: false)) {
        try {
          await entity.delete(recursive: true);
        } on FileSystemException {
          // Best-effort cache cleanup.
        }
      }
    }
  }

  Future<int> _directorySize(Directory directory) async {
    if (!await directory.exists()) {
      return 0;
    }
    var total = 0;
    await for (final entity in directory.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }
}
