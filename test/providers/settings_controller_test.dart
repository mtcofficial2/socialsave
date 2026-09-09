import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/features/settings/domain/entities/app_settings.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';

import '../helpers/fakes.dart';

void main() {
  test('theme switching persists through the repository', () async {
    final repo = FakeSettingsRepository();
    final container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(repo),
        initialSettingsProvider.overrideWithValue(const AppSettings()),
      ],
    );
    addTearDown(container.dispose);

    await container.read(settingsControllerProvider.notifier).setThemeMode(ThemeMode.dark);
    expect(container.read(settingsControllerProvider).themeMode, ThemeMode.dark);
    expect(repo.value.themeMode, ThemeMode.dark);
  });
}
