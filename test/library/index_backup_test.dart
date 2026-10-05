import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/library/index_backup.dart';
import 'package:social_save/features/library/library_catalog.dart';

void main() {
  test('encrypted library index round trips', () async {
    const backup = IndexBackup();
    const catalog = LibraryCatalog(
      favorites: {'device:1'},
      collections: {'Trips': ['device:1']},
      notes: {'device:1': 'Keep'},
    );
    final payload = jsonEncode({
      'records': [
        {'title': 'Flower', 'sourceUrl': 'https://example.com/flower.mp4'},
      ],
      'catalog': catalog.encode(),
    });
    final sealed = await backup.seal(payload, 'correct horse');
    final opened = await backup.open(sealed, 'correct horse');
    expect(opened, payload);
    final decoded = jsonDecode(opened) as Map<String, dynamic>;
    final restored = LibraryCatalog.decode(decoded['catalog'] as String);
    expect(restored.isFavorite('device:1'), isTrue);
    expect(restored.inCollection('Trips', 'device:1'), isTrue);
    expect(restored.notes['device:1'], 'Keep');
  });

  test('wrong passphrase does not open the index', () async {
    const backup = IndexBackup();
    final sealed = await backup.seal('{"records":[]}', 'right-pass');
    expect(
      () => backup.open(Uint8List.fromList(sealed), 'wrong-pass'),
      throwsA(isA<Exception>()),
    );
  });
}
