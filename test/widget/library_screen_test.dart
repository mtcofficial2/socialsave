import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/theme/app_colors.dart';
import 'package:social_save/features/library/presentation/library_screen_v2.dart';
import 'package:social_save/features/library/presentation/vault_lock.dart';
import 'package:social_save/features/library/vault_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<VaultService> vault() async {
    return VaultService(await SharedPreferences.getInstance());
  }

  testWidgets('library chrome stays compact in light mode', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [vaultServiceProvider.overrideWithValue(await vault())],
        child: MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: AppColors.lightScheme(),
          ),
          home: const LibraryScreenV2(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Library'), findsOneWidget);
    expect(find.byKey(const ValueKey('library-menu')), findsOneWidget);
    expect(find.text('Search by title'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Vault'));
    await tester.pump();
    expect(find.text('Create PIN'), findsOneWidget);
    final key = find.ancestor(
      of: find.text('5'),
      matching: find.byType(InkResponse),
    );
    expect(tester.getSize(key).width, inInclusiveRange(80, 96));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 20));
  });

  testWidgets('vault keypad grows under the short header', (tester) async {
    SharedPreferences.setMockInitialValues({'vault.pin.hash': 'set'});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<void> pumpPane(ColorScheme scheme) async {
      final theme = ThemeData(
        useMaterial3: true,
        brightness: scheme.brightness,
        colorScheme: scheme,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [vaultServiceProvider.overrideWithValue(await vault())],
          child: MaterialApp(
            key: ValueKey(scheme.brightness),
            theme: theme,
            darkTheme: theme,
            themeMode: scheme.brightness == Brightness.dark
                ? ThemeMode.dark
                : ThemeMode.light,
            home: Scaffold(
              key: ValueKey('pane-${scheme.brightness}'),
              body: const Column(
                children: [
                  SizedBox(height: 110),
                  Expanded(child: VaultLockPane()),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    await pumpPane(AppColors.lightScheme());
    expect(find.text('Enter PIN'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('Enter PIN')).style?.color,
      AppColors.lightScheme().onSurface,
    );
    final lightKey = find.ancestor(
      of: find.text('5'),
      matching: find.byType(InkResponse),
    );
    expect(tester.getSize(lightKey).width, inInclusiveRange(80, 96));
    _expectEvenDial(tester);

    await pumpPane(AppColors.darkScheme());
    expect(find.text('Enter PIN'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('Enter PIN')).style?.color,
      AppColors.darkScheme().onSurface,
    );
    final darkKey = find.ancestor(
      of: find.text('5'),
      matching: find.byType(InkResponse),
    );
    expect(tester.getSize(darkKey).width, inInclusiveRange(80, 96));
    _expectEvenDial(tester);
    expect(tester.takeException(), isNull);
  });
}

void _expectEvenDial(WidgetTester tester) {
  Rect circle(String digit) {
    return tester.getRect(
      find.ancestor(
        of: find.text(digit),
        matching: find.byType(InkResponse),
      ),
    );
  }

  final four = circle('4');
  final five = circle('5');
  final six = circle('6');
  final eight = circle('8');
  // Keys sit on an even 3-column grid: same gaps across, 8 straight below 5.
  final left = five.center.dx - four.center.dx;
  final right = six.center.dx - five.center.dx;
  expect((left - right).abs(), lessThan(1));
  expect((eight.center.dx - five.center.dx).abs(), lessThan(1));
  expect(eight.top, greaterThanOrEqualTo(five.bottom - 0.5));

  final paneTop = tester.getTopLeft(find.byType(VaultLockPane)).dy;
  final paneHeight = tester.getSize(find.byType(VaultLockPane)).height;
  final mid = paneTop + paneHeight / 2;
  expect(five.center.dy, greaterThan(mid - paneHeight * 0.08));
  expect(five.center.dy, lessThan(paneTop + paneHeight * 0.72));
}
