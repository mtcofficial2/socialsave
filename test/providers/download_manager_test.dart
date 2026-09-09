import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/network/connectivity_service.dart';
import 'package:social_save/core/storage/download_path_service.dart';
import 'package:social_save/features/downloader/data/datasources/file_downloader.dart';
import 'package:social_save/features/downloader/presentation/providers/download_manager.dart';
import 'package:social_save/features/downloads/data/datasources/download_history_store.dart';
import 'package:social_save/features/settings/domain/entities/app_settings.dart';
import 'package:social_save/shared/models/download_status.dart';

import '../helpers/fakes.dart';

class _FakePaths extends DownloadPathService {
  _FakePaths(this.directory);

  final Directory directory;

  @override
  Future<File> createTargetFile({
    required String title,
    required String format,
    String? quality,
    required DownloadLocation location,
  }) async {
    return File('${directory.path}/video.mp4');
  }
}

class _RecordingDownloader implements FileDownloader {
  bool fail = false;

  @override
  Future<RemoteFileProbe> probe(String url, {CancelToken? cancelToken}) async {
    return const RemoteFileProbe(supportsResume: true, contentLength: 4);
  }

  @override
  Future<void> download({
    required String url,
    required String savePath,
    required CancelToken cancelToken,
    int startByte = 0,
    void Function(DownloadProgress progress)? onProgress,
  }) async {
    final file = File(savePath);
    await file.create(recursive: true);
    onProgress?.call(const DownloadProgress(received: 2, total: 4));
    if (cancelToken.isCancelled) {
      throw DioException(
        requestOptions: RequestOptions(),
        type: DioExceptionType.cancel,
      );
    }
    if (fail) {
      throw const SocketException('offline');
    }
    await file.writeAsBytes([1, 2, 3, 4]);
    onProgress?.call(const DownloadProgress(received: 4, total: 4));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(NetworkAccess.wifi);
  });

  late Directory temp;
  late MockMediaRepository media;
  late _RecordingDownloader downloader;
  late InMemoryDownloadHistoryStore history;
  late FakeSettingsRepository settingsRepo;
  late MockNotificationService notifications;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('socialsave');
    media = MockMediaRepository();
    downloader = _RecordingDownloader();
    history = InMemoryDownloadHistoryStore();
    settingsRepo = FakeSettingsRepository();
    notifications = MockNotificationService();
    when(
      () => media.requestDownload(
        url: any(named: 'url'),
        formatId: any(named: 'formatId'),
      ),
    ).thenAnswer((_) async => sampleTicket());
    when(
      () => notifications.showDownloadComplete(
        id: any(named: 'id'),
        title: any(named: 'title'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => notifications.showDownloadFailed(
        id: any(named: 'id'),
        title: any(named: 'title'),
      ),
    ).thenAnswer((_) async {});
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  ProviderContainer buildContainer({
    MockConnectivityService? connectivity,
    AppSettings settings = const AppSettings(),
  }) {
    final net = connectivity ?? MockConnectivityService();
    if (connectivity == null) {
      when(() => net.current()).thenAnswer((_) async => NetworkAccess.wifi);
      when(
        () => net.canDownload(
          access: any(named: 'access'),
          wifiOnly: any(named: 'wifiOnly'),
        ),
      ).thenReturn(true);
    }
    return ProviderContainer(
      overrides: [
        mediaRepositoryProvider.overrideWithValue(media),
        downloadsRepositoryProvider.overrideWithValue(history),
        fileDownloaderProvider.overrideWithValue(downloader),
        downloadPathServiceProvider.overrideWithValue(_FakePaths(temp)),
        connectivityServiceProvider.overrideWithValue(net),
        permissionServiceProvider.overrideWithValue(const FakePermissionService()),
        notificationServiceProvider.overrideWithValue(notifications),
        settingsRepositoryProvider.overrideWithValue(settingsRepo),
        initialSettingsProvider.overrideWithValue(settings),
      ],
    );
  }

  test('completes a download and writes history', () async {
    final ref = buildContainer();
    addTearDown(ref.dispose);
    final task = await ref.read(downloadManagerProvider.notifier).enqueue(
          media: sampleMedia(),
          format: sampleMedia().formats.first,
        );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(
      ref.read(downloadManagerProvider).byId(task.id)?.status,
      DownloadStatus.completed,
    );
    expect(await history.getAll(), isNotEmpty);
  });

  test('cancel marks the task cancelled', () async {
    final ref = buildContainer();
    addTearDown(ref.dispose);
    final manager = ref.read(downloadManagerProvider.notifier);
    final task = await manager.enqueue(
      media: sampleMedia(),
      format: sampleMedia().formats.first,
      start: false,
    );
    await manager.cancel(task.id);
    expect(
      ref.read(downloadManagerProvider).byId(task.id)?.status,
      DownloadStatus.cancelled,
    );
  });

  test('retry restarts a failed download', () async {
    downloader.fail = true;
    final ref = buildContainer();
    addTearDown(ref.dispose);
    final manager = ref.read(downloadManagerProvider.notifier);
    final task = await manager.enqueue(
      media: sampleMedia(),
      format: sampleMedia().formats.first,
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(
      ref.read(downloadManagerProvider).byId(task.id)?.status,
      DownloadStatus.failed,
    );
    downloader.fail = false;
    await manager.retry(task.id);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(
      ref.read(downloadManagerProvider).byId(task.id)?.status,
      DownloadStatus.completed,
    );
  });

  test('wifi-only blocks cellular', () async {
    final connectivity = MockConnectivityService();
    when(() => connectivity.current()).thenAnswer((_) async => NetworkAccess.cellular);
    when(
      () => connectivity.canDownload(
        access: any(named: 'access'),
        wifiOnly: any(named: 'wifiOnly'),
      ),
    ).thenReturn(false);
    final ref = buildContainer(
      connectivity: connectivity,
      settings: const AppSettings(wifiOnly: true),
    );
    addTearDown(ref.dispose);
    expect(
      () => ref.read(downloadManagerProvider.notifier).enqueue(
            media: sampleMedia(),
            format: sampleMedia().formats.first,
          ),
      throwsA(isA<Exception>()),
    );
  });
}
