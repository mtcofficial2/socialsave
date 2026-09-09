import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/features/downloads/data/datasources/download_history_store.dart';
import 'package:social_save/features/settings/domain/entities/app_settings.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';
import 'package:social_save/features/settings/presentation/screens/settings_screen.dart';

import '../helpers/fakes.dart';

void main() {
  testWidgets('theme segmented control updates settings', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(FakeSettingsRepository()),
          initialSettingsProvider.overrideWithValue(const AppSettings()),
          downloadsRepositoryProvider.overrideWithValue(
            InMemoryDownloadHistoryStore(),
          ),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsScreen)),
    );
    expect(container.read(settingsControllerProvider).themeMode, ThemeMode.dark);
  });
}
