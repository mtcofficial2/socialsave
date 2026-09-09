import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:social_save/app.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/features/downloads/data/datasources/download_history_store.dart';
import 'package:social_save/features/settings/domain/entities/app_settings.dart';

import '../test/helpers/fakes.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app boots to home and can open settings', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(FakeSettingsRepository()),
          initialSettingsProvider.overrideWithValue(const AppSettings()),
          downloadsRepositoryProvider.overrideWithValue(
            InMemoryDownloadHistoryStore(),
          ),
        ],
        child: const SocialSaveApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Analyze'), findsOneWidget);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Wi-Fi only'), findsOneWidget);
  });
}
