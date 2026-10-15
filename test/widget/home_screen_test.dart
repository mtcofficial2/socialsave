import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/network/connectivity_service.dart';
import 'package:social_save/features/downloads/data/datasources/download_history_store.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/home/presentation/screens/home_screen.dart';
import 'package:social_save/shared/models/download_status.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/features/library/presentation/library_screen.dart'
    show vaultServiceProvider;
import 'package:social_save/features/library/vault_service.dart';
import 'package:social_save/features/settings/domain/entities/app_settings.dart';
import 'package:social_save/shared/models/platform_catalog.dart';

import '../helpers/fakes.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<VaultService> vault() async {
    return VaultService(await SharedPreferences.getInstance());
  }

  testWidgets('home screen shows URL input, paste, and analyze', (
    tester,
  ) async {
    final media = MockMediaRepository();
    when(
      () => media.getPlatforms(),
    ).thenAnswer((_) async => PlatformCapability.fallbackCatalog());
    final connectivity = MockConnectivityService();
    when(
      () => connectivity.current(),
    ).thenAnswer((_) async => NetworkAccess.wifi);
    tester.view.physicalSize = const Size(1200, 2800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaRepositoryProvider.overrideWithValue(media),
          downloadsRepositoryProvider.overrideWithValue(
            InMemoryDownloadHistoryStore(),
          ),
          connectivityServiceProvider.overrideWithValue(connectivity),
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(),
          ),
          initialSettingsProvider.overrideWithValue(const AppSettings()),
          vaultServiceProvider.overrideWithValue(await vault()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    // Nearby share keeps a small spinner while it looks for devices.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const Key('url-input')), findsOneWidget);
    expect(find.byKey(const Key('paste-button')), findsOneWidget);
    expect(find.byKey(const Key('analyze-button')), findsOneWidget);
    expect(find.text('Save a public playlist'), findsOneWidget);
    expect(find.text('Compliance Notice'), findsOneWidget);
    expect(find.text('Supported Platforms'), findsOneWidget);
  });

  testWidgets('analyze with empty URL shows an error', (tester) async {
    final media = MockMediaRepository();
    when(
      () => media.getPlatforms(),
    ).thenAnswer((_) async => PlatformCapability.fallbackCatalog());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaRepositoryProvider.overrideWithValue(media),
          downloadsRepositoryProvider.overrideWithValue(
            InMemoryDownloadHistoryStore(),
          ),
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(),
          ),
          initialSettingsProvider.overrideWithValue(const AppSettings()),
          vaultServiceProvider.overrideWithValue(await vault()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const Key('analyze-button')));
    await tester.pump();
    expect(find.textContaining('Paste a video URL'), findsWidgets);
  });

  testWidgets('a recent link fills the field and stays on home', (
    tester,
  ) async {
    final media = MockMediaRepository();
    when(
      () => media.getPlatforms(),
    ).thenAnswer((_) async => PlatformCapability.fallbackCatalog());
    final connectivity = MockConnectivityService();
    when(
      () => connectivity.current(),
    ).thenAnswer((_) async => NetworkAccess.wifi);
    final store = InMemoryDownloadHistoryStore();
    const url = 'https://example.com/flower-talk.mp4';
    await store.upsert(
      DownloadRecord(
        id: 'older',
        title: 'Garden walk',
        sourceUrl: url,
        platform: SocialPlatform.direct,
        downloadedAt: DateTime.utc(2026, 1, 2),
        status: DownloadStatus.completed,
      ),
    );
    await store.upsert(
      DownloadRecord(
        id: 'newer',
        title: 'Garden walk again',
        sourceUrl: url,
        platform: SocialPlatform.direct,
        downloadedAt: DateTime.utc(2026, 1, 3),
        status: DownloadStatus.completed,
      ),
    );
    tester.view.physicalSize = const Size(1200, 2800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaRepositoryProvider.overrideWithValue(media),
          downloadsRepositoryProvider.overrideWithValue(store),
          connectivityServiceProvider.overrideWithValue(connectivity),
          settingsRepositoryProvider.overrideWithValue(
            FakeSettingsRepository(),
          ),
          initialSettingsProvider.overrideWithValue(const AppSettings()),
          vaultServiceProvider.overrideWithValue(await vault()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final chip = find.byKey(const ValueKey('recent-link-$url'));
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await tester.pump();

    final field = tester.widget<TextField>(find.byKey(const Key('url-input')));
    expect(field.controller?.text, url);
    expect(find.byKey(const Key('analyze-button')), findsOneWidget);
    expect(find.text('Recent links'), findsOneWidget);
  });
}
