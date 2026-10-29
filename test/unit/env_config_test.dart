import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/core/config/env_config.dart';

void main() {
  test('the public source does not name a deployed server or a client key', () {
    expect(EnvConfig.productionApiBaseUrl, isEmpty);
    expect(EnvConfig.apiKey, isEmpty);
  });
}
