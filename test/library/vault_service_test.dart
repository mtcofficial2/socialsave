import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/features/library/vault_service.dart';

void main() {
  test('vault PIN is stored hashed and only the matching PIN unlocks', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final vault = VaultService(prefs);

    expect(vault.hasPin, isFalse);
    expect(vault.verifyPin('1234'), isFalse);

    await vault.setPin('2468');
    expect(vault.hasPin, isTrue);
    expect(vault.verifyPin('2468'), isTrue);
    expect(vault.verifyPin('1234'), isFalse);
    expect(prefs.getString('vault.pin.hash'), isNot('2468'));
    expect(prefs.getString('vault.pin.salt'), isNotEmpty);
  });

  test('vault restore uses a public filename from the title', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final vault = VaultService(prefs);
    final item = VaultItem(
      id: 'abc',
      title: 'Private clip',
      fileName: 'abc.mp4',
      bytes: 12,
      addedAt: DateTime(2026, 1, 1),
    );
    expect(vault.publicFileName(item), 'Private clip.mp4');
    expect(vault.mimeType(item), 'video/mp4');
  });
}
