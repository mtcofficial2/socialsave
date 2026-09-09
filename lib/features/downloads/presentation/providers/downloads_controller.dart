import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';

final downloadsControllerProvider =
    AsyncNotifierProvider<DownloadsController, List<DownloadRecord>>(
  DownloadsController.new,
);

class DownloadsController extends AsyncNotifier<List<DownloadRecord>> {
  @override
  Future<List<DownloadRecord>> build() {
    return ref.read(downloadsRepositoryProvider).getAll();
  }

  Future<void> refresh() async {
    state = const AsyncLoading<List<DownloadRecord>>().copyWithPrevious(state);
    state = await AsyncValue.guard(
      () => ref.read(downloadsRepositoryProvider).getAll(),
    );
  }

  Future<void> delete(String id, {required bool deleteFile}) async {
    await ref.read(downloadsRepositoryProvider).delete(
          id,
          deleteFile: deleteFile,
        );
    await refresh();
  }

  Future<void> clear({required bool deleteFiles}) async {
    await ref.read(downloadsRepositoryProvider).clear(deleteFiles: deleteFiles);
    await refresh();
  }

  Future<void> open(DownloadRecord record) async {
    final path = record.localPath;
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      throw const AppException(
        code: AppErrorCode.removedVideo,
        message: 'The file is no longer on this device.',
      );
    }
    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done) {
      throw AppException(
        code: AppErrorCode.unknown,
        message: result.message,
      );
    }
  }

  Future<void> share(DownloadRecord record) async {
    final path = record.localPath;
    if (path == null || !File(path).existsSync()) {
      throw const AppException(
        code: AppErrorCode.removedVideo,
        message: 'The file is no longer on this device.',
      );
    }
    await SharePlus.instance.share(
      ShareParams(files: [XFile(path)], text: record.title),
    );
  }

  Future<void> shareOrThrow(DownloadRecord record) => share(record);
}


