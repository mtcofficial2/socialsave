import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Shared page spacing: 16 px gutters on phones, and on wide windows the
/// content is centred at [maxWidth] instead of stretching edge to edge.
EdgeInsets pagePadding(
  BuildContext context, {
  double top = 0,
  double bottom = 24,
  double maxWidth = 860,
}) {
  final width = MediaQuery.sizeOf(context).width;
  final side = math.max(16.0, (width - maxWidth) / 2);
  return EdgeInsets.fromLTRB(side, top, side, bottom);
}

/// Standard spacing steps (4-pt grid).
class Gap {
  const Gap._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
}
