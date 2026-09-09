import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/core/utils/formatters.dart';

void main() {
  const formatters = Formatters();

  test('formats bytes', () {
    expect(formatters.bytes(512), '512 B');
    expect(formatters.bytes(2048), '2.00 KB');
    expect(formatters.bytes(5 * 1024 * 1024), '5.00 MB');
  });

  test('formats duration', () {
    expect(formatters.duration(5), '00:05');
    expect(formatters.duration(65), '01:05');
    expect(formatters.duration(3661), '1:01:01');
  });

  test('formats percent', () {
    expect(formatters.percent(0.42), '42%');
  });
}
