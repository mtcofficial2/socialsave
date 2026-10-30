import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/downloader/data/repositories/routing_media_repository.dart';

void main() {
  test('TikTok-ready Auto, Best, and Original ask for 1080p', () {
    expect(hostedFormatId('auto+tt'), '1080p');
    expect(hostedFormatId('best+tt'), '1080p');
    expect(hostedFormatId('original+tt'), '1080p');
    expect(hostedFormatId('default+tt'), '1080p');
    expect(hostedFormatId('+tt'), '1080p');
  });

  test('an explicit height and a normal download stay as chosen', () {
    expect(hostedFormatId('720p+tt'), '720p');
    expect(hostedFormatId('1080p+tt'), '1080p');
    expect(hostedFormatId('480p+tt'), '480p');
    expect(hostedFormatId('2160p+tt'), '2160p');
    expect(hostedFormatId('auto'), 'auto');
    expect(hostedFormatId('best'), 'best');
    expect(hostedFormatId('original'), 'original');
    expect(hostedFormatId('1080p'), '1080p');
  });
}
