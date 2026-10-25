import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/library/library_sync.dart';

void main() {
  test('a cancelled suggestion is not offered again', () {
    const url = 'https://youtu.be/abc12345678';
    expect(LibrarySync.acceptsSuggestion(url, {}, {}), isTrue);
    expect(LibrarySync.acceptsSuggestion('  $url  ', {url}, {}), isFalse);
    expect(LibrarySync.acceptsSuggestion(url, {}, {url}), isFalse);
    expect(LibrarySync.acceptsSuggestion('   ', {}, {}), isFalse);
  });
}
