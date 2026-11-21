import 'package:flutter/material.dart';

/// What a snackbar is telling the user. Picks the leading icon and tint.
enum AppSnackKind { info, success, error }

/// One consistent way to show a short message at the bottom of the screen.
///
/// ```dart
/// AppSnack.success(context, 'Saved to Downloads');
/// AppSnack.error(context, 'Could not open that file.');
/// AppSnack.info(context, 'Removed', actionLabel: 'Undo', onAction: restore);
/// ```
///
/// The look (floating, rounded, glass in dark mode) comes from the app's
/// [SnackBarThemeData]; this adds a status icon, replaces the message that is
/// already showing instead of queueing behind it, and keeps errors on screen
/// a little longer so they can be read.
abstract final class AppSnack {
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? info(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
  }) =>
      show(context, message,
          kind: AppSnackKind.info, actionLabel: actionLabel, onAction: onAction, duration: duration);

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? success(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
  }) =>
      show(context, message,
          kind: AppSnackKind.success, actionLabel: actionLabel, onAction: onAction, duration: duration);

  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? error(
    BuildContext context,
    String message, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
  }) =>
      show(context, message,
          kind: AppSnackKind.error, actionLabel: actionLabel, onAction: onAction, duration: duration);

  /// Shows [message]. Returns null when there is no [ScaffoldMessenger]
  /// above [context] (for example while the app is still starting).
  static ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? show(
    BuildContext context,
    String message, {
    AppSnackKind kind = AppSnackKind.info,
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return null;
    final snack = build(
      context,
      message,
      kind: kind,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );
    messenger.hideCurrentSnackBar();
    return messenger.showSnackBar(snack);
  }

  /// The [SnackBar] itself, for code that holds a [ScaffoldMessengerState]
  /// across an `await` and shows it later.
  static SnackBar build(
    BuildContext context,
    String message, {
    AppSnackKind kind = AppSnackKind.info,
    String? actionLabel,
    VoidCallback? onAction,
    Duration? duration,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final (IconData icon, Color color) = switch (kind) {
      AppSnackKind.success => (
          Icons.check_circle_rounded,
          dark ? const Color(0xFF4ADE80) : const Color(0xFF86EFAC),
        ),
      AppSnackKind.error => (
          Icons.error_rounded,
          dark ? const Color(0xFFF87171) : const Color(0xFFFCA5A5),
        ),
      AppSnackKind.info => (
          Icons.info_rounded,
          dark ? scheme.primary : scheme.inversePrimary,
        ),
    };
    return SnackBar(
      duration: duration ??
          (kind == AppSnackKind.error || onAction != null
              ? const Duration(seconds: 6)
              : const Duration(seconds: 4)),
      content: Semantics(
        liveRegion: true,
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
      ),
      action: actionLabel != null && onAction != null
          ? SnackBarAction(label: actionLabel, onPressed: onAction)
          : null,
    );
  }
}
