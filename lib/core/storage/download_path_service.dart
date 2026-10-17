import 'dart:io';
import 'package:social_save/core/platform/plat.dart';

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
      // Android: write straight to the public Download/SocialSave (one copy).
      // The app-private downloads folder is only used on other platforms.
      if (Plat.isWindows) {
        // 1.0.37: Windows saves to Documents\SocialSave, the same folder
        // that received files use. Older saves in Downloads\SocialSave stay
        // in the Library (both folders are scanned).
        final home = Platform.environment['USERPROFILE'];
        if (home != null && home.isNotEmpty) {
          candidates.insert(
            0,
            Directory(p.join(home, 'Documents', AppConstants.defaultFolderName)),
          );
        }
      }
      final systemDownloads =
          Plat.isAndroid || Plat.isWindows ? null : await getDownloadsDirectory();
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

  // On Windows the temporary directory is the user's whole %TEMP%, shared
  // with every other program. Only SocialSave's own entries count as cache
  // there (1.0.37: "Clear" used to try to empty all of %TEMP%).
  static const _windowsCacheDirs = {'socialsave_thumbs', 'session_send'};
  static final _windowsCacheFiles = RegExp(r'^(ss_shot_\d+\.png|ss_recycle_\d+\.txt)$');

  /// Folders a live transfer reads from; kept while [keepTransfers] is set.
  static const _transferDirs = {'send', 'session_send'};

  Future<List<FileSystemEntity>> _cacheEntries({bool keepTransfers = false}) async {
    final temp = await getTemporaryDirectory();
    if (!await temp.exists()) return const [];
    final out = <FileSystemEntity>[];
    await for (final entity in temp.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (keepTransfers && _transferDirs.contains(name)) continue;
      if (Plat.isWindows &&
          !_windowsCacheDirs.contains(name) &&
          !_windowsCacheFiles.hasMatch(name)) {
        continue;
      }
      out.add(entity);
    }
    return out;
  }

  Future<int> cacheSizeBytes() async {
    var total = 0;
    for (final entity in await _cacheEntries()) {
      try {
        if (entity is File) {
          total += await entity.length();
        } else if (entity is Directory) {
          total += await _directorySize(entity);
        }
      } on FileSystemException {
        // Files can vanish while we count.
      }
    }
    return total;
  }

  /// Deletes SocialSave's temporary files. [keepTransfers] leaves the copies
  /// a connected share session may still be sending.
  Future<void> clearCache({bool keepTransfers = false}) async {
    for (final entity in await _cacheEntries(keepTransfers: keepTransfers)) {
      try {
        await entity.delete(recursive: true);
      } on FileSystemException {
        // Best-effort cache cleanup.
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
