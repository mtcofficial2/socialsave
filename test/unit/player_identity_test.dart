import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/core/platform/player_identity.dart';

void main() {
  test('a pc beacon is a PC player and anything else is a phone player', () {
    expect(playerNameForKind('pc'), 'PC player');
    expect(playerNameForKind('phone'), 'Phone player');
    expect(playerNameForKind(''), 'Phone player');
  });
}
