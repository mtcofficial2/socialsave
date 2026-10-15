import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/player/presentation/widgets/phone_player_chrome.dart';

void main() {
  test('resolution uses the shorter side', () {
    expect(phoneResolutionLabel(1920, 1080), '1080p');
    expect(phoneResolutionLabel(1080, 1920), '1080p');
    expect(phoneResolutionLabel(1280, 720), '720p');
    expect(phoneResolutionLabel(null, 1080), isNull);
  });

  test('speed badge matches the player mock', () {
    expect(phoneRateLabel(1), '1.0x');
    expect(phoneRateLabel(1.5), '1.5x');
    expect(phoneRateLabel(1.25), '1.25x');
    expect(phoneRateLabel(0.75), '0.75x');
  });
}
