import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/config/build_flags.dart';
import 'package:social_save/core/engine/phone_engine.dart';
import 'package:social_save/core/utils/file_utils.dart';
import 'package:social_save/core/engine/local_engine.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/platform/media_events.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/core/platform/phone_body.dart';
import 'package:social_save/core/platform/phone_power.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/storage/download_path_service.dart';
import 'package:social_save/core/storage/media_store_service.dart';
import 'package:social_save/core/errors/error_mapper.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/downloads/presentation/providers/downloads_controller.dart';
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
import 'package:social_save/web/web_saver.dart';
import 'package:social_save/core/config/hosted_api.dart';
import 'package:uuid/uuid.dart';

final downloadManagerProvider =
    NotifierProvider<DownloadManager, DownloadManagerState>(DownloadManager.new);

/// The app UI registers this. The round bubble answers first when it is showing.
typedef InAppTiktokAsk = Future<bool> Function(String title);

InAppTiktokAsk? inAppTiktokAsk;

/// Asked when Download is tapped for a video: true = TikTok-ready, false = just download.
Future<bool?> Function(String title)? inAppTiktokChoice;

/// Opens the live prep progress on screen; returns its close call (null: no screen).
void Function()? Function()? inAppPrepProgress;

/// Tasks the user asked to make TikTok-ready (capped pick plus prep).
final Set<String> _tiktokTasks = <String>{};

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
  final Map<String, StreamSubscription<NetworkAccess>> _wifiWaits = {};
  final Set<String> _powerHolds = {};
  StreamSubscription<PhoneSnapshot>? _phoneSub;
  final ErrorMapper _errorMapper = const ErrorMapper();
  final Uuid _uuid = const Uuid();
  var _restored = false;
  var _alive = true;
  DateTime? _lastSignal;

  @override
  DownloadManagerState build() {
    LocalEngine.busyCheck = () => stateOrNull?.active.isNotEmpty ?? false;
    MediaEvents.on('downloadAction', (args) async {
      if (args is! Map) return;
      final action = '${args['action']}';
      final id = '${args['id']}';
      if (action == 'pause') await pause(id);
      if (action == 'cancel') await cancel(id);
      if (action == 'resume') await resume(id);
    });
    if (!kIsWeb) PhoneBody.ensure();
    _phoneSub = PhoneBody.snapshots.stream.listen((_) {
      unawaited(_applyPower());
    });
    ref.onDispose(() {
      _alive = false;
      MediaEvents.off('downloadAction');
      unawaited(_phoneSub?.cancel());
      for (final sub in _wifiWaits.values) {
        unawaited(sub.cancel());
      }
      unawaited(_stopSignal());
    });
    Future<void>(() async {
      if (!_alive) return;
      await _restore();
      if (!_alive) return;
      await _applyPower();
    });
    return const DownloadManagerState();
  }

  Future<DownloadTask> enqueue({
    required MediaInfo media,
    required MediaFormat format,
    bool start = true,
  }) async {
    final settings = ref.read(settingsControllerProvider);
    await _assertNetwork(settings);
    if (await _alreadySaved(media.sourceUrl, format.quality, format.format)) {
      throw const AppException(
        code: AppErrorCode.unknown,
        message: ErrorMessages.alreadySaved,
      );
    }

    // The browser asks no storage permission; it saves to its Downloads.
    final allowed = kIsWeb ||
        await ref
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

    final tiktok = Plat.isAndroid && _videoFormat(format.id) && await _chooseTiktok(media.title);
    final ticket = await ref.read(mediaRepositoryProvider).requestDownload(
          url: media.sourceUrl,
          formatId: tiktok ? '${format.id}+tt' : format.id,
        );

    final id = _uuid.v4();
    if (tiktok) _tiktokTasks.add(id);
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

    if (kIsWeb) {
      // No file to prepare: the browser saves it when the download finishes.
      state = state.copyWithTask(task);
      if (start) {
        unawaited(this.start(id));
      } else {
        await _persist();
      }
      return state.byId(id) ?? task;
    }

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
      final power = _powerReason(settings);
      if (await _wifiBlocked(settings)) {
        await _parkForWifi(task);
      } else if (power != null) {
        await _holdForPower(task, power);
      } else {
        unawaited(this.start(id));
      }
    } else {
      await _persist();
    }
    return state.byId(id) ?? task;
  }

  Future<void> start(String id) async {
    final existing = state.byId(id);
    if (existing == null) {
      return;
    }
    final settings = ref.read(settingsControllerProvider);
    await _assertNetwork(settings);
    if (await _wifiBlocked(settings)) {
      await _parkForWifi(existing);
      return;
    }
    final power = _powerReason(settings);
    if (power != null) {
      await _holdForPower(existing, power);
      return;
    }
    _powerHolds.remove(id);
    await _wifiWaits.remove(id)?.cancel();
    if (kIsWeb) {
      await _startWeb(id, existing);
      return;
    }

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
      if (task.downloadUrl.isEmpty &&
          (task.jobId ?? '').isEmpty &&
          (task.directUrl ?? '').isEmpty) {
        // A retry of an on-phone save (or "Try with server"): prepare again.
        final fresh = await ref.read(mediaRepositoryProvider).requestDownload(
              url: task.sourceUrl,
              formatId: _fid(task),
            );
        task = task.copyWith(
          jobId: fresh.jobId ?? '',
          downloadUrl: fresh.isReady ? fresh.downloadUrl : '',
          directUrl: fresh.directUrl,
          totalBytes: fresh.filesize ?? task.totalBytes,
        );
        state = state.copyWithTask(task);
      }
      if (task.downloadUrl.isEmpty && (task.jobId ?? '').isNotEmpty) {
        final ready = await _waitIfNeeded(
          DownloadTicket(
            downloadUrl: '',
            jobId: task.jobId,
            state: DownloadJobState.processing,
          ),
          taskId: task.id,
        );
        final engineDone = state.byId(task.id)?.prepareFraction;
        task = (state.byId(task.id) ?? task).copyWith(
          downloadUrl: ready.downloadUrl,
          directUrl: ready.directUrl ?? task.directUrl,
          totalBytes: ready.filesize ?? task.totalBytes,
          // The local copy finishes the same bar (no reset to 0%).
          phase: engineDone == null ? null : 'saving',
          prepareFraction: engineDone == null ? null : 0.99,
          receivedBytes: engineDone == null ? null : 0,
          bytesPerSecond: 0,
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
        final grace = HostedApi.matches(url)
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
              final next = current.copyWith(
                receivedBytes: progress.received,
                totalBytes: progress.total ?? current.totalBytes,
                bytesPerSecond: tracker.bytesPerSecond,
                downloadUrl: url,
              );
              state = state.copyWithTask(next);
              unawaited(_signal(next));
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

      final loaded = state.byId(id);
      if (loaded == null) {
        return;
      }
      // Keep a non-null task. Reassigning the promoted `loaded` value
      // makes Dart treat it as nullable again.
      DownloadTask readyTask = loaded;
      var savedPath = loaded.localPath;
      if (Plat.isAndroid && savedPath != null && _tiktokVideo(savedPath)) {
        var needs = false;
        try {
          needs = await MediaStoreService().needsTiktokWork(savedPath);
        } catch (_) {}
        if (needs && !token.isCancelled) {
          // Only when the user chose "Yes, TikTok-ready" at Download.
          final yes = _tiktokTasks.contains(readyTask.id);
          if (token.isCancelled) return;
          if (yes) {
            final working = readyTask.copyWith(phase: 'shareable', bytesPerSecond: 0);
            state = state.copyWithTask(working);
            await _signal(working);
            final closePrep = inAppPrepProgress?.call();
            try {
              final ready = await MediaStoreService().makeUploadReady(savedPath);
              if (ready != null && ready.isNotEmpty) {
                savedPath = ready;
                readyTask = readyTask.copyWith(localPath: ready);
              }
            } catch (_) {}
            closePrep?.call();
          }
        }
      }
      final finished = readyTask.copyWith(
        status: DownloadStatus.completed,
        receivedBytes: readyTask.totalBytes ?? readyTask.receivedBytes,
        bytesPerSecond: 0,
        clearPhase: true,
      );
      await ref.read(downloadsRepositoryProvider).upsert(
            DownloadRecord.fromTask(finished),
          );
      // Recent downloads and the Library list read the history; refresh it.
      ref.invalidate(downloadsControllerProvider);
      state = state.copyWithTask(finished);
      await _persist();
      await _signalActive();
      final doneSettings = ref.read(settingsControllerProvider);
      if (doneSettings.hapticAlerts) {
        unawaited(PhoneBody.vibrate(saved: true));
      }
      final candidate = savedPath;
      if (candidate != null && File(candidate).existsSync()) {
        final String publishPath = candidate;
        unawaited(() async {
          try {
            final published = await MediaStoreService().publishToDownloads(
              sourcePath: publishPath,
              fileName: p.basename(publishPath),
              mimeType: switch (p.extension(publishPath).toLowerCase()) {
                '.webm' => 'video/webm',
                '.mp3' => 'audio/mpeg',
                '.m4a' => 'audio/mp4',
                _ => 'video/mp4',
              },
            );
            final tree = ref.read(settingsControllerProvider).saveTreeUri;
            if (tree != null && tree.isNotEmpty) {
              await PhoneBody.copyIntoFolder(
                treeUri: tree,
                path: publishPath,
                name: p.basename(publishPath),
              );
            }
            if (published == null || published.isEmpty) {
              await MediaStoreService().scanFile(publishPath);
            } else if (!published.startsWith('content:') && published != publishPath) {
              final latest = state.byId(id);
              if (latest != null) {
                final updated = latest.copyWith(localPath: published);
                state = state.copyWithTask(updated);
                await ref.read(downloadsRepositoryProvider).upsert(
                      DownloadRecord.fromTask(updated),
                    );
              }
            }
          } catch (_) {}
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

  /// Web build: fetch the file in the browser, hand it to the browser's
  /// Downloads, and keep a blob URL so it can be played in this tab.
  Future<void> _startWeb(String id, DownloadTask existing) async {
    final token = CancelToken();
    _tokens[id] = token;
    _speeds[id] = _SpeedTracker();
    var task = existing.copyWith(
      status: DownloadStatus.running,
      receivedBytes: 0,
      clearError: true,
    );
    state = state.copyWithTask(task);
    try {
      if (task.downloadUrl.isEmpty) {
        final ready = await _webReadyTicket(task, () => token.isCancelled);
        if (token.isCancelled) return;
        task = task.copyWith(
          downloadUrl: ready.downloadUrl,
          jobId: ready.jobId ?? '',
          directUrl: ready.directUrl ?? task.directUrl,
          totalBytes: ready.filesize ?? task.totalBytes,
        );
        state = state.copyWithTask(task);
      }
      final urls = _candidateUrls(task).toList();
      if (urls.isEmpty) {
        throw const AppException(
          code: AppErrorCode.serverError,
          message: ErrorMessages.serverError,
        );
      }
      final result = await webFetchAndSave(
        urls: urls,
        fileName: _webFileName(task),
        storeKey: id,
        cancelled: token.whenCancel.then((_) {}),
        onProgress: (received, total) {
          final current = state.byId(id);
          if (current == null || current.status != DownloadStatus.running) return;
          final tracker = _speeds[id] ?? _SpeedTracker();
          tracker.record(received);
          state = state.copyWithTask(
            current.copyWith(
              receivedBytes: received,
              totalBytes: total ?? current.totalBytes,
              bytesPerSecond: tracker.bytesPerSecond,
            ),
          );
        },
      );
      if (token.isCancelled) return;
      final completed = state.byId(id);
      if (completed == null) return;
      final note = !result.fetched
          ? 'Your browser is downloading this video. Check its Downloads.'
          : (result.stored
              ? null
              : 'Saved to your Downloads. This browser had no room to keep a copy for the Library.');
      final finished = completed.copyWith(
        status: DownloadStatus.completed,
        localPath: result.url,
        receivedBytes: completed.totalBytes ?? completed.receivedBytes,
        bytesPerSecond: 0,
        errorMessage: note,
        clearError: note == null,
      );
      await ref.read(downloadsRepositoryProvider).upsert(
            DownloadRecord.fromTask(finished),
          );
      // Recent downloads and the Library list read the history; refresh it.
      ref.invalidate(downloadsControllerProvider);
      state = state.copyWithTask(finished);
      await _persist();
    } catch (error) {
      if (token.isCancelled) return;
      await _fail(
        id,
        error is AppException ? error : _errorMapper.fromObject(error),
      );
    } finally {
      _tokens.remove(id);
    }
  }

  /// Web: waits for the server's prepared file. When the job is gone or
  /// failed (or this is a retry), asks the server to prepare it again once.
  Future<DownloadTicket> _webReadyTicket(
    DownloadTask task,
    bool Function() cancelled,
  ) async {
    final jobId = task.jobId ?? '';
    Object? firstError;
    if (jobId.isNotEmpty) {
      try {
        return await _waitIfNeeded(
          DownloadTicket(
            downloadUrl: '',
            jobId: jobId,
            state: DownloadJobState.processing,
          ),
          taskId: task.id,
        );
      } catch (error) {
        firstError = error;
        // A real refusal (private, removed, too large) will not change on a
        // second try; a storage hiccup or an expired job may.
        if (error is AppException &&
            error.code != AppErrorCode.timeout &&
            !error.message.toLowerCase().contains('stored') &&
            !error.message.toLowerCase().contains('try again')) {
          rethrow;
        }
      }
    }
    if (cancelled()) {
      throw firstError ?? const AppException(code: AppErrorCode.unknown, message: 'Download cancelled.');
    }
    final fresh = await ref.read(mediaRepositoryProvider).requestDownload(
          url: task.sourceUrl,
          formatId: _fid(task),
        );
    final current = state.byId(task.id);
    if (current != null && fresh.jobId != null) {
      state = state.copyWithTask(current.copyWith(jobId: fresh.jobId));
    }
    return _waitIfNeeded(fresh, taskId: task.id);
  }

  String _webFileName(DownloadTask task) {
    var base = task.title.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]+'), ' ').trim();
    if (base.isEmpty) base = 'SocialSave video';
    if (base.length > 80) base = base.substring(0, 80).trim();
    final ext = task.format.format.trim().toLowerCase();
    return '$base.${ext.isEmpty ? 'mp4' : ext}';
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
    if (HostedApi.matches(host) ||
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
    _powerHolds.remove(id);
    _tokens[id]?.cancel('paused');
    final paused = task.copyWith(status: DownloadStatus.paused, bytesPerSecond: 0);
    state = state.copyWithTask(paused);
    await _persist();
    await _signal(paused);
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
    await _wifiWaits.remove(id)?.cancel();
    _tokens[id]?.cancel('cancelled');
    try {
      await MediaStoreService().cancelUploadPrep();
    } catch (_) {}
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
    await _persist();
    await _signalActive();
  }

  Future<void> retry(String id) async {
    final task = state.byId(id);
    if (task == null || !task.status.canRetry) {
      return;
    }
    if (!kIsWeb) await _deletePartial(task.localPath);
    // Web: the old server job failed or its link expired. On-phone engine:
    // the job is gone. "Try with server": the server prepares it. In all
    // three cases, prepare again.
    final fresh = kIsWeb ||
        (task.jobId?.startsWith(PhoneEngine.jobPrefix) ?? false) ||
        PhoneEngine.serverFor.contains(task.sourceUrl);
    state = state.copyWithTask(
      task.copyWith(
        status: DownloadStatus.queued,
        receivedBytes: 0,
        bytesPerSecond: 0,
        clearError: true,
        clearPhase: true,
        downloadUrl: fresh ? '' : null,
        jobId: fresh ? '' : null,
        directUrl: fresh ? '' : null,
      ),
    );
    await start(id);
  }

  Future<DownloadTicket> _waitIfNeeded(DownloadTicket ticket, {String? taskId}) async {
    if ((kLocalEngine || (ticket.jobId?.startsWith(PhoneEngine.jobPrefix) ?? false)) &&
        ticket.jobId != null &&
        !ticket.isReady) {
      return _waitForLocalJob(ticket.jobId!, taskId);
    }
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

  /// Desktop engine: the "prepare" step is the whole YouTube download and
  /// merge on this PC, so a fixed 4-minute limit failed long 1080p/4K saves.
  /// Waits while the engine keeps making progress (15 min stall limit),
  /// shows that progress on the task, and stops on pause or cancel.
  Future<DownloadTicket> _waitForLocalJob(String jobId, String? taskId) async {
    final repository = ref.read(mediaRepositoryProvider);
    final started = DateTime.now();
    var lastProgress = 0.0;
    var lastReceived = 0;
    var lastChange = DateTime.now();
    while (DateTime.now().difference(started) < const Duration(hours: 12)) {
      // The engine is on this device: poll often so the bar moves in small steps.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (taskId != null) {
        final task = state.byId(taskId);
        if (task == null || !task.status.isActive || task.status == DownloadStatus.paused) {
          if (jobId.startsWith(PhoneEngine.jobPrefix)) unawaited(PhoneEngine.cancel(jobId));
          throw const AppException(code: AppErrorCode.unknown, message: 'Download cancelled.');
        }
      }
      final status = await repository.getJobStatus(jobId);
      if (status.state == DownloadJobState.ready && (status.downloadUrl ?? '').isNotEmpty) {
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
      // 1.0.38: one smooth bar. The engine folds the video, the audio and
      // the merge into one 0..0.99 value, with real bytes and speed. Before,
      // the bar only moved when the size was known in advance (often not, for
      // TikTok and merged YouTube), then jumped to 100% at the end.
      final progress = (status.progress ?? 0).clamp(0.0, 0.99).toDouble();
      final received = status.downloadedBytes ?? 0;
      if (progress > lastProgress + 0.0005 || received > lastReceived) {
        lastChange = DateTime.now();
      } else if (DateTime.now().difference(lastChange) > const Duration(minutes: 15)) {
        break;
      }
      if (progress > lastProgress) lastProgress = progress;
      if (received > lastReceived) lastReceived = received;
      final task = taskId == null ? null : state.byId(taskId);
      if (task != null && task.status == DownloadStatus.running) {
        final known = task.totalBytes ?? task.format.filesize ?? status.filesize;
        final engineTotal = status.totalBytes ?? 0;
        final total = engineTotal > 0 ? engineTotal : known;
        final bytes = received > 0
            ? received
            : (total != null && total > 0 ? (lastProgress * total).round() : 0);
        final next = task.copyWith(
          phase: status.phase == 'merging' ? 'merging' : 'preparing',
          prepareFraction: lastProgress,
          receivedBytes: bytes,
          totalBytes: (total != null && total > 0) ? total : null,
          bytesPerSecond: status.phase == 'merging' ? 0 : (status.speed ?? 0),
        );
        if (next != task) {
          state = state.copyWithTask(next);
          unawaited(_signal(next));
        }
      }
    }
    throw const AppException(code: AppErrorCode.timeout, message: ErrorMessages.timeout);
  }

  Future<void> _fail(String id, AppException error) async {
    try {
      final task = state.byId(id);
      if (task == null || task.status == DownloadStatus.completed) {
        return;
      }
      final failed = task.copyWith(
        status: DownloadStatus.failed,
        bytesPerSecond: 0,
        errorMessage: error.message,
      );
      state = state.copyWithTask(failed);
      final settings = ref.read(settingsControllerProvider);
      if (settings.hapticAlerts) {
        unawaited(PhoneBody.vibrate(saved: false));
      }
      if (settings.notificationsEnabled) {
        await ref.read(notificationServiceProvider).showDownloadFailed(
              id: failed.id,
              title: failed.title,
            );
      }
      await _persist();
      await _signalActive();
    } catch (_) {}
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

  Future<bool> _wifiBlocked(AppSettings settings) async {
    // Web: the browser cannot tell Wi-Fi from mobile data reliably.
    if (kIsWeb) return false;
    final connectivity = ref.read(connectivityServiceProvider);
    final access = await connectivity.current();
    return !connectivity.canDownload(access: access, wifiOnly: settings.wifiOnly);
  }

  String? _powerReason(AppSettings settings) {
    final snap = PhoneBody.latest;
    return powerHoldReason(
      onlyWhileCharging: settings.onlyWhileCharging,
      pauseBelowBattery: settings.pauseBelowBattery,
      pocketPause: settings.pocketPause,
      known: snap.known,
      battery: snap.battery,
      charging: snap.charging,
      pocket: snap.pocket,
    );
  }

  Future<void> _holdForPower(DownloadTask task, String reason) async {
    _powerHolds.add(task.id);
    _tokens[task.id]?.cancel('power');
    final waiting = task.copyWith(
      status: DownloadStatus.waitingPower,
      bytesPerSecond: 0,
      errorMessage: reason,
    );
    state = state.copyWithTask(waiting);
    await _persist();
    await _signal(waiting);
  }

  Future<void> _applyPower() async {
    if (!_alive) return;
    final settings = ref.read(settingsControllerProvider);
    final reason = _powerReason(settings);
    for (final task in state.tasks.values.toList()) {
      if (reason != null && task.status == DownloadStatus.running) {
        final latest = state.byId(task.id) ?? task;
        if (latest.status == DownloadStatus.running) {
          await _holdForPower(latest, reason);
        }
      } else if (reason == null &&
          task.status == DownloadStatus.waitingPower &&
          _powerHolds.contains(task.id) &&
          !_tokens.containsKey(task.id)) {
        if (!await _wifiBlocked(settings)) {
          unawaited(start(task.id));
        }
      }
    }
  }

  Future<void> _parkForWifi(DownloadTask task) async {
    final waiting = task.copyWith(
      status: DownloadStatus.waitingWifi,
      bytesPerSecond: 0,
      errorMessage: 'Waiting for Wi-Fi.',
    );
    state = state.copyWithTask(waiting);
    await _armWifi(task.id);
    await _persist();
    await _signal(waiting);
  }

  Future<void> _armWifi(String id) async {
    await _wifiWaits.remove(id)?.cancel();
    _wifiWaits[id] = ref.read(connectivityServiceProvider).onChange.listen((access) {
      final settings = ref.read(settingsControllerProvider);
      final allowed = ref.read(connectivityServiceProvider).canDownload(
            access: access,
            wifiOnly: settings.wifiOnly,
          );
      final task = state.byId(id);
      if (allowed && task != null && task.status == DownloadStatus.waitingWifi) {
        unawaited(start(id));
      }
    });
  }

  Future<bool> _alreadySaved(String url, String quality, String format) async {
    if (kIsWeb) return false;
    // Same quality but another type (audio M4A vs MP3) is a different file.
    final ext = '.${const FileUtils().extensionFor(format)}';
    final records = await ref.read(downloadsRepositoryProvider).getAll();
    for (final record in records) {
      if (record.status != DownloadStatus.completed) continue;
      if (record.sourceUrl != url) continue;
      if ((record.quality ?? '').toLowerCase() != quality.toLowerCase()) continue;
      final path = record.localPath;
      if (path == null || !File(path).existsSync()) continue;
      if (p.extension(path).toLowerCase() != ext) continue;
      return true;
    }
    return false;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final active = state.tasks.values.where((task) => task.status.isActive).toList();
      await prefs.setString(
        'socialsave_active_downloads',
        jsonEncode(active.map((task) => task.toJson()).toList()),
      );
      await prefs.setBool('socialsave_resume_pending', active.isNotEmpty);
    } catch (_) {}
  }

  Future<void> _restore() async {
    if (_restored || !_alive) return;
    _restored = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!_alive) return;
      final raw = prefs.getString('socialsave_active_downloads');
      if (raw == null || raw.isEmpty) return;
      final data = jsonDecode(raw);
      if (data is! List || !_alive) return;
      for (final item in data) {
        if (!_alive) return;
        if (item is! Map) continue;
        final task = DownloadTask.fromJson(Map<String, dynamic>.from(item));
        if (task.id.isEmpty || !task.status.isActive) continue;
        if (state.byId(task.id) != null) continue;
        final resumed = task.status == DownloadStatus.running
            ? task.copyWith(status: DownloadStatus.paused, bytesPerSecond: 0)
            : task;
        state = state.copyWithTask(resumed);
        if (task.status == DownloadStatus.running ||
            task.status == DownloadStatus.waitingWifi ||
            task.status == DownloadStatus.waitingPower) {
          if (task.status == DownloadStatus.waitingPower) {
            _powerHolds.add(resumed.id);
          }
          unawaited(start(resumed.id));
        }
      }
    } catch (_) {}
  }

  Future<void> _signal(DownloadTask task) async {
    final now = DateTime.now();
    if (task.status == DownloadStatus.running &&
        _lastSignal != null &&
        now.difference(_lastSignal!) < const Duration(seconds: 1)) {
      return;
    }
    _lastSignal = now;
    final settings = ref.read(settingsControllerProvider);
    if (!settings.notificationsEnabled) return;
    final progress = (task.progress * 100).round().clamp(0, 100);
    final text = task.status == DownloadStatus.waitingWifi
        ? 'Waiting for Wi-Fi'
        : task.status == DownloadStatus.waitingPower
            ? (task.errorMessage ?? 'Waiting for the phone')
            : task.status == DownloadStatus.paused
                ? 'Paused'
                : task.phase == 'askTiktok'
                    ? 'Make this one work on TikTok?'
                    : task.phase == 'shareable'
                    ? 'Making a file TikTok can open…'
                    : task.phase == 'merging'
                    ? 'Merging video and sound…'
                    : task.bytesPerSecond <= 0
                    ? 'Starting'
                    : '${(task.bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    try {
      await MediaEvents.channel.invokeMethod<void>('keepAlive', {
        'id': task.id,
        'title': task.title,
        'text': text,
        'progress': progress,
        'paused': task.status != DownloadStatus.running,
      });
    } catch (_) {}
  }

  Future<void> _signalActive() async {
    DownloadTask? active;
    for (final task in state.tasks.values) {
      if (task.status == DownloadStatus.running ||
          task.status == DownloadStatus.paused ||
          task.status == DownloadStatus.waitingWifi ||
          task.status == DownloadStatus.waitingPower) {
        active = task;
        break;
      }
    }
    if (active == null) {
      await _stopSignal();
      return;
    }
    _lastSignal = null;
    await _signal(active);
  }

  Future<void> _stopSignal() async {
    try {
      await MediaEvents.channel.invokeMethod<void>('stopKeepAlive');
    } catch (_) {}
  }

  Future<int> _existingBytes(String? path) async {
    if (path == null || kIsWeb) {
      return 0;
    }
    final file = File(path);
    if (await file.exists()) {
      return file.length();
    }
    return 0;
  }

  Future<bool> _askTiktok(String title) async {
    try {
      final onBubble = await MediaStoreService().askTiktokOnBubble(title);
      if (onBubble != null) return onBubble;
    } catch (_) {}
    final ask = inAppTiktokAsk;
    if (ask == null) return false;
    try {
      return await ask(title);
    } catch (_) {
      return false;
    }
  }

  String _fid(DownloadTask task) =>
      _tiktokTasks.contains(task.id) ? '${task.format.id}+tt' : task.format.id;

  bool _videoFormat(String id) => !id.startsWith('audio') && id != 'preview';

  Future<bool> _chooseTiktok(String title) async {
    final ask = inAppTiktokChoice;
    if (ask != null) {
      try {
        final pick = await ask(title);
        if (pick != null) return pick;
      } catch (_) {}
    }
    // App not on screen (share sheet, bubble): ask on the bubble.
    return _askTiktok(title);
  }

  bool _tiktokVideo(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.mp4':
      case '.m4v':
      case '.mov':
      case '.mkv':
      case '.webm':
        return true;
      default:
        return false;
    }
  }

  Future<void> _deletePartial(String? path) async {
    if (path == null || kIsWeb) {
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
