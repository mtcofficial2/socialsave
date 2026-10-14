import 'package:flutter/foundation.dart';

/// This app is a phone player or a PC player.
String get thisPlayerName =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows ? 'PC player' : 'Phone player';

/// Label for a device whose beacon [kind] is `pc` or `phone`.
String playerNameForKind(String kind) => kind == 'pc' ? 'PC player' : 'Phone player';
