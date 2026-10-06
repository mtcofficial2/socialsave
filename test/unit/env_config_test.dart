import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/core/config/env_config.dart';

void main() {
  test('the release API is the public SocialSave host', () {
    final uri = Uri.parse(EnvConfig.productionApiBaseUrl);
    expect(uri.scheme, 'https');
    expect(uri.host, 'socialsave-api-p2tm.onrender.com');
    expect(uri.host.startsWith('10.'), isFalse);
    expect(uri.host, isNot('10.0.2.2'));
  });
}
