import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/downloader/data/datasources/byte_ranges.dart';

void main() {
  test('ranges cover the file once without overlap', () {
    final ranges = planByteRanges(1000, 8);
    expect(ranges, isNotEmpty);
    var cursor = 0;
    final seen = <String>{};
    for (final range in ranges) {
      expect(range.start, cursor);
      expect(range.end, greaterThanOrEqualTo(range.start));
      expect(seen.add(range.header), isTrue);
      cursor = range.end + 1;
    }
    expect(cursor, 1000);
    expect(contentRangeTotal('bytes 0-124/1000', 0, 124), 1000);
    expect(contentRangeTotal('bytes 1-124/1000', 0, 124), isNull);
  });
}
