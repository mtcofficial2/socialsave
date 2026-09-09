import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/core/network/connectivity_service.dart';
import 'package:social_save/core/network/dio_client.dart';
import 'package:social_save/core/notifications/notification_service.dart';
import 'package:social_save/core/permissions/permission_service.dart';
import 'package:social_save/core/storage/download_path_service.dart';
import 'package:social_save/core/utils/formatters.dart';
import 'package:social_save/core/utils/platform_detector.dart';
import 'package:social_save/core/utils/url_validator.dart';
import 'package:social_save/features/downloader/data/datasources/file_downloader.dart';
import 'package:social_save/features/downloader/data/datasources/media_api_client.dart';
import 'package:social_save/features/downloader/data/repositories/media_repository_impl.dart';
import 'package:social_save/features/downloader/domain/repositories/media_repository.dart';
import 'package:social_save/features/downloads/data/datasources/download_history_store.dart';
import 'package:social_save/features/downloads/domain/repositories/downloads_repository.dart';
import 'package:social_save/features/settings/domain/entities/app_settings.dart';
import 'package:social_save/features/settings/domain/repositories/settings_repository.dart';
import 'package:social_save/shared/models/platform_catalog.dart';

final urlValidatorProvider = Provider<UrlValidator>((ref) => const UrlValidator());

final platformDetectorProvider =
    Provider<PlatformDetector>((ref) => const PlatformDetector());

final formattersProvider = Provider<Formatters>((ref) => const Formatters());

final connectivityServiceProvider =
    Provider<ConnectivityService>((ref) => ConnectivityService());

final dioClientProvider = Provider<DioClient>((ref) => DioClient());

final mediaApiClientProvider = Provider<MediaApiClient>(
  (ref) => MediaApiClient(ref.watch(dioClientProvider)),
);

final mediaRepositoryProvider = Provider<MediaRepository>(
  (ref) => MediaRepositoryImpl(
    apiClient: ref.watch(mediaApiClientProvider),
    connectivity: ref.watch(connectivityServiceProvider),
    urlValidator: ref.watch(urlValidatorProvider),
  ),
);

final fileDownloaderProvider = Provider<FileDownloader>(
  (ref) => DioFileDownloader(),
);

final downloadPathServiceProvider = Provider<DownloadPathService>(
  (ref) => DownloadPathService(),
);

final permissionServiceProvider = Provider<PermissionService>(
  (ref) => const PermissionService(),
);

final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService(),
);

final thumbnailCacheManagerProvider = Provider<BaseCacheManager>(
  (ref) => DefaultCacheManager(),
);

/// Overridden in `main()` after Hive is opened.
final downloadsRepositoryProvider = Provider<DownloadsRepository>(
  (ref) => InMemoryDownloadHistoryStore(),
);

/// Overridden in `main()` after SharedPreferences is loaded.
final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => throw StateError('settingsRepositoryProvider must be overridden'),
);

/// Overridden in `main()` with persisted settings.
final initialSettingsProvider = Provider<AppSettings>(
  (ref) => const AppSettings(),
);

final platformCatalogProvider = FutureProvider<List<PlatformCapability>>((ref) {
  return ref.watch(mediaRepositoryProvider).getPlatforms();
});
