import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/storage/download_path_service.dart';
import 'package:social_save/core/storage/media_store_service.dart';
import 'package:social_save/core/errors/error_mapper.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';
import 'package:social_save/core/errors/error_messages.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/core/network/connectivity_service.dart';
import 'package:social_save/features/settings/domain/entities/app_settings.dart';
import 'package:social_save/shared/models/download_status.dart';
import 'package:social_save/shared/models/download_task.dart';
import 'package:social_save/shared/models/download_ticket.dart';
import 'package:social_save/shared/models/media_format.dart';
import 'package:social_save/shared/models/media_info.dart';
import 'package:uuid/uuid.dart';

final downloadManagerProvider =
    NotifierProvider<DownloadManager, DownloadManagerState>(DownloadManager.new);

class DownloadManagerState {
  const DownloadManagerState({this.tasks = const {}});

  final Map<String, DownloadTask> tasks;

  List<DownloadTask> get active {
    final items = tasks.values.where((task) => task.status.isActive).toList();
    items.sort((a, b) {
      final aDate = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bDate = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bDate.compareTo(aDate);
    });
    return items;
  }

  DownloadTask? get current {
    for (final task in tasks.values) {
      if (task.status == DownloadStatus.running) {
        return task;
      }
    }
    return active.isEmpty ? null : active.first;
  }

  DownloadTask? byId(String id) => tasks[id];

  DownloadManagerState copyWithTask(DownloadTask task) {
    return DownloadManagerState(tasks: {...tasks, task.id: task});
  }
}

class DownloadManager extends Notifier<DownloadManagerState> {
  final Map<String, CancelToken> _tokens = {};
  final Map<String, _SpeedTracker> _speeds = {};
  final ErrorMapper _errorMapper = const ErrorMapper();
  final Uuid _uuid = const Uuid();

  @override
  DownloadManagerState build() => const DownloadManagerState();

  Future<DownloadTask> enqueue({
    required MediaInfo media,
    required MediaFormat format,
    bool start = true,
  }) async {
    final settings = ref.read(settingsControllerProvider);
    await _assertNetwork(settings);

    final allowed = await ref
        .read(permissionServiceProvider)
        .ensureDownloadPermissions(settings.downloadLocation);
    if (!allowed) {
      throw const AppException(
        code: AppErrorCode.permissionDenied,
        message: ErrorMessages.permissionDenied,
      );
    }

    if (!media.canDownload) {
      throw AppException(
        code: AppErrorCode.downloadNotPermitted,
        message: media.downloadRestrictedReason ??
            ErrorMessages.downloadNotPermitted,
      );
    }

    final ticket = await ref.read(mediaRepositoryProvider).requestDownload(
          url: media.sourceUrl,
          formatId: format.id,
        );

    final id = _uuid.v4();
    var task = DownloadTask.fromMedia(
      id: id,
      media: media,
      format: format,
      downloadUrl: ticket.downloadUrl,
      totalBytes: ticket.filesize ?? format.filesize,
      jobId: ticket.jobId,
      directUrl: ticket.directUrl,
      requestHeaders: ticket.requestHeaders,
    );

    File target;
    try {
      target = await ref.read(downloadPathServiceProvider).createTargetFile(
            title: media.title,
            format: format.format,
            quality: format.quality,
            location: settings.downloadLocation,
          );
    } catch (_) {
      target = await ref.read(downloadPathServiceProvider).createTargetFile(
            title: media.title,
            format: format.format,
            quality: format.quality,
            location: DownloadLocation.appStorage,
          );
    }
    task = task.copyWith(localPath: target.path);
    state = state.copyWithTask(task);

    if (start && settings.autoStartDownloads) {
      unawaited(this.start(id));
    }
    return task;
  }

  Future<void> start(String id) async {
    final existing = state.byId(id);
    if (existing == null) {
      return;
    }
    await _assertNetwork(ref.read(settingsControllerProvider));

    final token = CancelToken();
    _tokens[id] = token;
    _speeds[id] = _SpeedTracker();

    var task = existing.copyWith(
      status: DownloadStatus.running,
      clearError: true,
    );
    state = state.copyWithTask(task);

    final downloader = ref.read(fileDownloaderProvider);
    try {
      if (task.downloadUrl.isEmpty && task.jobId != null) {
        final ready = await _waitIfNeeded(
          DownloadTicket(
            downloadUrl: '',
            jobId: task.jobId,
            state: DownloadJobState.processing,
          ),
        );
        task = task.copyWith(
          downloadUrl: ready.downloadUrl,
          directUrl: ready.directUrl ?? task.directUrl,
          totalBytes: ready.filesize ?? task.totalBytes,
        );
        state = state.copyWithTask(task);
      }
      if (task.downloadUrl.isEmpty && (task.directUrl == null || task.directUrl!.isEmpty)) {
        throw const AppException(
          code: AppErrorCode.serverError,
          message: ErrorMessages.serverError,
        );
      }
      Object? lastError;
      var downloaded = false;
      for (final url in _candidateUrls(task)) {
        final attempt = CancelToken();
        unawaited(token.whenCancel.then((_) {
          if (!attempt.isCancelled) attempt.cancel();
        }));
        var gotBytes = false;
        final grace = url.contains('onrender.com')
            ? const Duration(seconds: 90)
            : const Duration(seconds: 25);
        final watchdog = Timer(grace, () {
          if (!gotBytes && !attempt.isCancelled) {
            attempt.cancel('slow-start');
          }
        });
        try {
          final startByte = await _existingBytes(task.localPath);
          await downloader.download(
            url: url,
            savePath: task.localPath!,
            cancelToken: attempt,
            startByte: startByte,
            extraHeaders: task.requestHeaders,
            onProgress: (progress) {
              if (progress.received > startByte) {
                gotBytes = true;
                watchdog.cancel();
              }
              final current = state.byId(id);
              if (current == null || current.status != DownloadStatus.running) {
                return;
              }
              final tracker = _speeds[id] ?? _SpeedTracker();
              tracker.record(progress.received);
              state = state.copyWithTask(
                current.copyWith(
                  receivedBytes: progress.received,
                  totalBytes: progress.total ?? current.totalBytes,
                  bytesPerSecond: tracker.bytesPerSecond,
                  downloadUrl: url,
                ),
              );
            },
          );
          downloaded = true;
          break;
        } catch (error) {
          lastError = error;
          if (token.isCancelled) rethrow;
        } finally {
          watchdog.cancel();
        }
      }
      if (!downloaded) {
        if (token.isCancelled) {
          return;
        }
        throw _mapAttemptError(lastError);
      }

      var completed = state.byId(id);
      if (completed == null) {
        return;
      }
      final savedPath = completed.localPath;
      final finished = completed.copyWith(
        status: DownloadStatus.completed,
        receivedBytes: completed.totalBytes ?? completed.receivedBytes,
        bytesPerSecond: 0,
      );
      state = state.copyWithTask(finished);
      await ref.read(downloadsRepositoryProvider).upsert(
            DownloadRecord.fromTask(finished),
          );
      if (savedPath != null && File(savedPath).existsSync()) {
        unawaited(() async {
          final published = await MediaStoreService().publishToDownloads(
            sourcePath: savedPath,
            fileName: p.basename(savedPath),
            mimeType: finished.format.format.toLowerCase() == 'webm'
                ? 'video/webm'
                : 'video/mp4',
          );
          if (published == null || published.isEmpty) {
            await MediaStoreService().scanFile(savedPath);
          } else if (!published.startsWith('content:') && published != savedPath) {
            final latest = state.byId(id);
            if (latest != null) {
              final updated = latest.copyWith(localPath: published);
              state = state.copyWithTask(updated);
              await ref.read(downloadsRepositoryProvider).upsert(
                    DownloadRecord.fromTask(updated),
                  );
            }
          }
        }());
      }
      final settings = ref.read(settingsControllerProvider);
      if (settings.notificationsEnabled) {
        await ref.read(notificationServiceProvider).showDownloadComplete(
              id: finished.id,
              title: finished.title,
            );
      }
    } on DioException catch (error) {
      if (token.isCancelled) {
        return;
      }
      await _fail(id, _errorMapper.fromDio(error));
    } catch (error) {
      if (token.isCancelled) {
        return;
      }
      await _fail(id, _errorMapper.fromObject(error));
    } finally {
      _tokens.remove(id);
    }
  }

  AppException _mapAttemptError(Object? error) {
    if (error is AppException) {
      if (error.code == AppErrorCode.downloadInterrupted) {
        return const AppException(
          code: AppErrorCode.timeout,
          message:
              'The download did not start in time. Check the link and try again.',
        );
      }
      return error;
    }
    if (error is DioException &&
        (CancelToken.isCancel(error) || error.type == DioExceptionType.cancel)) {
      return const AppException(
        code: AppErrorCode.timeout,
        message:
            'The download did not start in time. Check the link and try again.',
      );
    }
    return _errorMapper.fromObject(error ?? 'Download failed.');
  }

  Iterable<String> _candidateUrls(DownloadTask task) {
    final urls = <String>[];
    void add(String? value) {
      if (value == null || value.isEmpty || urls.contains(value)) return;
      urls.add(value);
    }

    if (_isUsableDirect(task.directUrl)) add(task.directUrl);
    add(task.downloadUrl);
    return urls;
  }

  bool _isUsableDirect(String? url) {
    if (url == null || url.isEmpty) return false;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;
    if (host.contains('onrender.com') ||
        host == 'localhost' ||
        host == '127.0.0.1' ||
        host.endsWith('.localhost')) {
      return false;
    }
    return true;
  }

  Future<void> pause(String id) async {
    final task = state.byId(id);
    if (task == null || !task.status.canPause) {
      return;
    }
    _tokens[id]?.cancel('paused');
    state = state.copyWithTask(
      task.copyWith(status: DownloadStatus.paused, bytesPerSecond: 0),
    );
  }

  Future<void> resume(String id) async {
    final task = state.byId(id);
    if (task == null || !task.status.canResume) {
      return;
    }
    await start(id);
  }

  Future<void> cancel(String id, {bool deletePartial = true}) async {
    final task = state.byId(id);
    if (task == null) {
      return;
    }
    _tokens[id]?.cancel('cancelled');
    if (deletePartial) {
      await _deletePartial(task.localPath);
    }
    state = state.copyWithTask(
      task.copyWith(
        status: DownloadStatus.cancelled,
        bytesPerSecond: 0,
        errorMessage: 'Download cancelled.',
      ),
    );
  }

  Future<void> retry(String id) async {
    final task = state.byId(id);
    if (task == null || !task.status.canRetry) {
      return;
    }
    await _deletePartial(task.localPath);
    state = state.copyWithTask(
      task.copyWith(
        status: DownloadStatus.queued,
        receivedBytes: 0,
        bytesPerSecond: 0,
        clearError: true,
      ),
    );
    await start(id);
  }

  Future<DownloadTicket> _waitIfNeeded(DownloadTicket ticket) async {
    if (ticket.isReady || ticket.jobId == null) {
      if (!ticket.isReady) {
        throw const AppException(
          code: AppErrorCode.serverError,
          message: ErrorMessages.serverError,
        );
      }
      return ticket;
    }
    final repository = ref.read(mediaRepositoryProvider);
    for (var i = 0; i < 120; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final status = await repository.getJobStatus(ticket.jobId!);
      if (status.state == DownloadJobState.ready &&
          (status.downloadUrl ?? '').isNotEmpty) {
        return DownloadTicket(
          downloadUrl: status.downloadUrl!,
          jobId: status.id,
          state: DownloadJobState.ready,
          filesize: status.filesize,
          directUrl: status.directUrl,
        );
      }
      if (status.state == DownloadJobState.failed) {
        throw AppException(
          code: AppErrorCode.serverError,
          message: status.errorMessage ?? ErrorMessages.serverError,
        );
      }
    }
    throw const AppException(
      code: AppErrorCode.timeout,
      message: ErrorMessages.timeout,
    );
  }

  Future<void> _fail(String id, AppException error) async {
    final task = state.byId(id);
    if (task == null) {
      return;
    }
    final failed = task.copyWith(
      status: DownloadStatus.failed,
      bytesPerSecond: 0,
      errorMessage: error.message,
    );
    state = state.copyWithTask(failed);
    final settings = ref.read(settingsControllerProvider);
    if (settings.notificationsEnabled) {
      await ref.read(notificationServiceProvider).showDownloadFailed(
            id: failed.id,
            title: failed.title,
          );
    }
  }

  Future<void> _assertNetwork(AppSettings settings) async {
    final connectivity = ref.read(connectivityServiceProvider);
    final access = await connectivity.current();
    if (access == NetworkAccess.offline) {
      throw const AppException(
        code: AppErrorCode.networkUnavailable,
        message: ErrorMessages.networkUnavailable,
      );
    }
  }

  Future<int> _existingBytes(String? path) async {
    if (path == null) {
      return 0;
    }
    final file = File(path);
    if (await file.exists()) {
      return file.length();
    }
    return 0;
  }

  Future<void> _deletePartial(String? path) async {
    if (path == null) {
      return;
    }
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

class _SpeedTracker {
  DateTime _lastTick = DateTime.now();
  int _lastBytes = 0;
  double bytesPerSecond = 0;

  void record(int received) {
    final now = DateTime.now();
    final elapsed = now.difference(_lastTick);
    if (elapsed < AppConstants.speedSampleWindow) {
      return;
    }
    final deltaBytes = received - _lastBytes;
    final inst = deltaBytes / (elapsed.inMilliseconds / 1000);
    bytesPerSecond =
        bytesPerSecond == 0 ? inst : bytesPerSecond * 0.7 + inst * 0.3;
    _lastTick = now;
    _lastBytes = received;
  }
}
