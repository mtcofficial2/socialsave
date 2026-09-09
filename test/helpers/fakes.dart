import 'package:mocktail/mocktail.dart';
import 'package:social_save/core/network/connectivity_service.dart';
import 'package:social_save/core/notifications/notification_service.dart';
import 'package:social_save/core/permissions/permission_service.dart';
import 'package:social_save/core/storage/download_path_service.dart';
import 'package:social_save/features/downloader/data/datasources/file_downloader.dart';
import 'package:social_save/features/downloader/data/datasources/media_api_client.dart';
import 'package:social_save/features/downloader/domain/repositories/media_repository.dart';
import 'package:social_save/features/downloads/domain/repositories/downloads_repository.dart';
import 'package:social_save/features/settings/domain/entities/app_settings.dart';
import 'package:social_save/features/settings/domain/repositories/settings_repository.dart';
import 'package:social_save/shared/models/download_ticket.dart';
import 'package:social_save/shared/models/media_format.dart';
import 'package:social_save/shared/models/media_info.dart';
import 'package:social_save/shared/models/platform_catalog.dart';
import 'package:social_save/shared/models/social_platform.dart';

class MockMediaRepository extends Mock implements MediaRepository {}

class MockMediaApiClient extends Mock implements MediaApiClient {}

class MockDownloadsRepository extends Mock implements DownloadsRepository {}

class MockFileDownloader extends Mock implements FileDownloader {}

class MockConnectivityService extends Mock implements ConnectivityService {}

class FakeSettingsRepository implements SettingsRepository {
  FakeSettingsRepository([this.value = const AppSettings()]);

  AppSettings value;

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async {
    value = settings;
  }
}

class FakePermissionService implements PermissionService {
  const FakePermissionService({this.allowed = true});

  final bool allowed;

  @override
  Future<bool> ensureDownloadPermissions(DownloadLocation location) async {
    return allowed;
  }
}

class MockNotificationService extends Mock implements NotificationService {}

MediaInfo sampleMedia({
  bool canDownload = true,
  SocialPlatform platform = SocialPlatform.direct,
}) {
  return MediaInfo(
    sourceUrl:
        'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
    platform: platform,
    title: 'Big Buck Bunny',
    author: 'Blender Foundation',
    durationSeconds: 596,
    canDownload: canDownload,
    formats: const [
      MediaFormat(
        id: 'original',
        quality: 'original',
        format: 'mp4',
        filesize: 158008374,
      ),
    ],
  );
}

DownloadTicket sampleTicket() {
  return const DownloadTicket(
    downloadUrl: 'https://example.com/files/abc',
    state: DownloadJobState.ready,
    filesize: 1000,
    fileName: 'video.mp4',
  );
}

List<PlatformCapability> sampleCatalog() => PlatformCapability.fallbackCatalog();
