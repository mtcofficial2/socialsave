import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/core/constants/app_constants.dart';

void main() {
  test('app constants are populated', () {
    expect(AppConstants.appName, 'SocialSave');
    expect(AppConstants.samplePublicVideoUrl, contains('http'));
  });
}
