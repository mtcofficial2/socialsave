import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/core/utils/url_validator.dart';

void main() {
  const validator = UrlValidator();

  test('accepts a public https URL', () {
    final result = validator.validate(
      'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
    );
    expect(result.isValid, isTrue);
    expect(result.normalized, isNotNull);
  });

  test('rejects empty input', () {
    expect(validator.validate('').isValid, isFalse);
  });

  test('rejects localhost', () {
    expect(validator.validate('http://localhost/video.mp4').isValid, isFalse);
  });

  test('rejects private IPv4', () {
    expect(validator.validate('http://192.168.0.5/a.mp4').isValid, isFalse);
    expect(validator.validate('http://10.0.0.8/a.mp4').isValid, isFalse);
    expect(validator.validate('http://127.0.0.1/a.mp4').isValid, isFalse);
  });

  test('rejects credentials in URL', () {
    expect(
      validator.validate('https://user:pass@example.com/a.mp4').isValid,
      isFalse,
    );
  });

  test('adds https when scheme is missing', () {
    final result = validator.validate('example.com/video.mp4');
    expect(result.isValid, isTrue);
    expect(result.normalized?.scheme, 'https');
  });
}
