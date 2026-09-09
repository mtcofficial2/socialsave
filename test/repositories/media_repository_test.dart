import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/core/network/connectivity_service.dart';
import 'package:social_save/core/utils/url_validator.dart';
import 'package:social_save/features/downloader/data/repositories/media_repository_impl.dart';
import 'package:social_save/shared/models/media_info.dart';

import '../helpers/fakes.dart';

void main() {
  late MockMediaApiClient api;
  late MockConnectivityService connectivity;
  late MediaRepositoryImpl repository;

  setUp(() {
    api = MockMediaApiClient();
    connectivity = MockConnectivityService();
    repository = MediaRepositoryImpl(
      apiClient: api,
      connectivity: connectivity,
      urlValidator: const UrlValidator(),
    );
    when(() => connectivity.current()).thenAnswer((_) async => NetworkAccess.wifi);
  });

  test('rejects invalid URLs before calling the API', () async {
    expect(
      () => repository.analyze('not a url'),
      throwsA(isA<AppException>().having((e) => e.code, 'code', AppErrorCode.invalidUrl)),
    );
    verifyNever(() => api.analyze(any()));
  });

  test('rejects offline analyze', () async {
    when(() => connectivity.current()).thenAnswer((_) async => NetworkAccess.offline);
    expect(
      () => repository.analyze('https://example.com/video.mp4'),
      throwsA(
        isA<AppException>().having(
          (e) => e.code,
          'code',
          AppErrorCode.networkUnavailable,
        ),
      ),
    );
  });

  test('returns API metadata', () async {
    final media = sampleMedia();
    when(() => api.analyze(any())).thenAnswer((_) async => media);
    final result = await repository.analyze(media.sourceUrl);
    expect(result.title, 'Big Buck Bunny');
    expect(result, isA<MediaInfo>());
  });
}
