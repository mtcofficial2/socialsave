import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/network/connectivity_service.dart';
import 'package:social_save/features/downloads/data/datasources/download_history_store.dart';
import 'package:social_save/features/home/presentation/screens/home_screen_v2.dart';
import 'package:social_save/features/library/presentation/vault_lock.dart'
    show vaultServiceProvider;
import 'package:social_save/features/library/vault_service.dart';
import 'package:social_save/features/settings/domain/entities/app_settings.dart';
import 'package:social_save/shared/models/platform_catalog.dart';

import '../helpers/fakes.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('home shows a greeting, the paste field, and every tool', (tester) async {
    final media = MockMediaRepository();
    when(() => media.getPlatforms()).thenAnswer((_) async => PlatformCapability.fallbackCatalog());
    final connectivity = MockConnectivityService();
    when(() => connectivity.current()).thenAnswer((_) async => NetworkAccess.wifi);
    tester.view.physicalSize = const Size(400, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaRepositoryProvider.overrideWithValue(media),
          downloadsRepositoryProvider.overrideWithValue(InMemoryDownloadHistoryStore()),
          connectivityServiceProvider.overrideWithValue(connectivity),
          settingsRepositoryProvider.overrideWithValue(FakeSettingsRepository()),
          initialSettingsProvider.overrideWithValue(const AppSettings()),
          vaultServiceProvider.overrideWithValue(VaultService(await SharedPreferences.getInstance())),
        ],
        child: const MaterialApp(home: HomeScreenV2()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Save a video'), findsOneWidget);
    expect(
      find.byWidgetPredicate((widget) {
        if (widget is! Text) return false;
        final data = widget.data ?? '';
        return data == 'Good morning' || data == 'Good afternoon' || data == 'Good evening';
      }),
      findsOneWidget,
    );
    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('Send files, chat, and play what you saved.'), findsOneWidget);
    expect(find.text('Nothing saved yet. Paste a public link above and it will show up here.'), findsOneWidget);
    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('Music'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
