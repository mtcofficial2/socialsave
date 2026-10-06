import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/core/platform/phone_power.dart';
import 'package:social_save/features/settings/domain/entities/app_settings.dart';

void main() {
  test('power holds stay off until the phone state is known', () {
    expect(
      powerHoldReason(
        onlyWhileCharging: true,
        pauseBelowBattery: true,
        pocketPause: true,
        known: false,
        battery: 5,
        charging: false,
        pocket: true,
      ),
      isNull,
    );
  });

  test('a charger keeps a low battery save running', () {
    expect(
      powerHoldReason(
        onlyWhileCharging: false,
        pauseBelowBattery: true,
        pocketPause: true,
        known: true,
        battery: 4,
        charging: true,
        pocket: false,
      ),
      isNull,
    );
  });

  test('only while charging waits until the phone is plugged in', () {
    expect(
      powerHoldReason(
        onlyWhileCharging: true,
        pauseBelowBattery: false,
        pocketPause: false,
        known: true,
        battery: 80,
        charging: false,
        pocket: false,
      ),
      'Waiting until the phone is charging.',
    );
  });

  test('under 15 percent pauses when the phone is not charging', () {
    expect(
      powerHoldReason(
        onlyWhileCharging: false,
        pauseBelowBattery: true,
        pocketPause: false,
        known: true,
        battery: 14,
        charging: false,
        pocket: false,
      ),
      'Paused below 15% battery.',
    );
  });

  test('a pocket pauses the save', () {
    expect(
      powerHoldReason(
        onlyWhileCharging: false,
        pauseBelowBattery: false,
        pocketPause: true,
        known: true,
        battery: 90,
        charging: true,
        pocket: true,
      ),
      'Paused while the phone is face down.',
    );
  });

  test('new phone settings keep the old constructor defaults', () {
    const settings = AppSettings();
    expect(settings.onlyWhileCharging, isFalse);
    expect(settings.pauseBelowBattery, isTrue);
    expect(settings.pocketPause, isTrue);
    expect(settings.headsetControls, isTrue);
    expect(settings.volumeKeysSeek, isTrue);
    expect(settings.hapticAlerts, isTrue);
    expect(settings.saveTreeUri, isNull);

    final restored = AppSettings.fromMap(settings.toMap());
    expect(restored.onlyWhileCharging, isFalse);
    expect(restored.pauseBelowBattery, isTrue);
    expect(restored.saveTreeUri, isNull);

    final withFolder = AppSettings.fromMap({
      ...settings.toMap(),
      'saveTreeUri': 'content://tree/downloads',
      'onlyWhileCharging': true,
    });
    expect(withFolder.saveTreeUri, 'content://tree/downloads');
    expect(withFolder.onlyWhileCharging, isTrue);
    expect(withFolder.copyWith(clearSaveTree: true).saveTreeUri, isNull);
  });
}
