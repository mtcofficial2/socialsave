import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Window width where the PC shell (sidebar) replaces the bottom bar.
const double kDesktopShellMinWidth = 840;

/// Width of [DesktopSidebar]. Page gutters subtract this so content is not
/// indented twice.
const double kDesktopSidebarWidth = 232;

/// Content-area width where a screen may split into two columns.
const double kDesktopSplitWidth = 900;

bool isDesktopShell(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= kDesktopShellMinWidth;

/// Marks the page area beside the desktop sidebar so gutters are not applied twice.
class DesktopChrome extends InheritedWidget {
  const DesktopChrome({super.key, required this.active, required super.child});

  final bool active;

  static bool of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<DesktopChrome>()?.active ?? false;
  }

  @override
  bool updateShouldNotify(DesktopChrome oldWidget) => active != oldWidget.active;
}

/// Page title: larger on a desktop window, unchanged on a phone.
TextStyle? pageTitleStyle(BuildContext context) {
  final text = Theme.of(context).textTheme;
  final style = isDesktopShell(context) ? text.headlineSmall : text.titleLarge;
  return style?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4);
}

/// Shared page spacing: 16 px gutters on phones, and on wide windows the
/// content is centred at [maxWidth] instead of stretching edge to edge.
EdgeInsets pagePadding(
  BuildContext context, {
  double top = 0,
  double bottom = 24,
  double maxWidth = 860,
}) {
  final width = MediaQuery.sizeOf(context).width;
  final desktop = width >= kDesktopShellMinWidth;
  // Callers that pass a reading measure (under 860) keep that column.
  final cap = desktop && maxWidth >= 860 ? 1120.0 : maxWidth;
  final gutter = desktop ? 28.0 : 16.0;
  final inSidebar = DesktopChrome.of(context);
  final contentWidth = inSidebar ? math.max(0.0, width - kDesktopSidebarWidth) : width;
  final side = math.max(gutter, (contentWidth - cap) / 2);
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
