import 'package:flutter/material.dart';

/// Colors from the cinematic library mock (appDark, appCard, accent violet).
class LibraryLook {
  const LibraryLook._();

  static const bg = Color(0xFF0B0B0F);
  static const card = Color(0xFF16161D);
  static const surface = Color(0xFF1F1F28);
  static const violet = Color(0xFF7C5CFF);
  static const violetHover = Color(0xFF6947F5);
  static const danger = Color(0xFFFF453A);
  static const success = Color(0xFF30D158);
  static const border = Color(0x14FFFFFF);
  static const violetDim = Color(0x267C5CFF);
  static const dangerDim = Color(0x26FF453A);

  static const radius = 16.0;
}

ThemeData libraryLookTheme(BuildContext context) {
  final base = Theme.of(context);
  const scheme = ColorScheme.dark(
    primary: LibraryLook.violet,
    onPrimary: Colors.white,
    secondary: LibraryLook.violet,
    onSecondary: Colors.white,
    surface: LibraryLook.bg,
    onSurface: Colors.white,
    error: LibraryLook.danger,
    onError: Colors.white,
    surfaceContainerHighest: LibraryLook.card,
    surfaceContainerHigh: LibraryLook.surface,
    surfaceContainer: Color(0xFF12121A),
    onSurfaceVariant: Color(0x99FFFFFF),
  );
  return base.copyWith(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: LibraryLook.bg,
    colorScheme: scheme,
    iconTheme: const IconThemeData(color: Colors.white),
    dividerColor: LibraryLook.border,
    textTheme: base.textTheme.apply(
      bodyColor: Colors.white,
      displayColor: Colors.white,
    ),
  );
}

/// `mm:ss`, or `h:mm:ss` once an hour is reached.
String libraryClock(int seconds) {
  if (seconds < 0) seconds = 0;
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:$mm:$ss';
  return '$mm:$ss';
}

String librarySize(int bytes) {
  if (bytes <= 0) return '';
  const mb = 1024 * 1024;
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}

/// Today, Yesterday, or `Oct 12`. Empty when the time is unknown.
String libraryWhen(DateTime? time, {DateTime? now}) {
  if (time == null) return '';
  final clock = now ?? DateTime.now();
  final day = DateTime(time.year, time.month, time.day);
  final today = DateTime(clock.year, clock.month, clock.day);
  if (day == today) return 'Today';
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[time.month - 1]} ${time.day}';
}

DateTime? libraryAdded(int epochMs) {
  if (epochMs <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(epochMs);
}

/// Platform name for a badge. Avoids treating a stray letter as X.
String? libraryPlatformBadge(String blob) {
  final lower = blob.toLowerCase();
  const named = [
    'youtube',
    'tiktok',
    'instagram',
    'facebook',
    'reddit',
    'pinterest',
  ];
  for (final name in named) {
    if (lower.contains(name)) {
      return name == 'youtube'
          ? 'YouTube'
          : name == 'tiktok'
          ? 'TikTok'
          : '${name[0].toUpperCase()}${name.substring(1)}';
    }
  }
  if (lower.contains('twitter') ||
      RegExp(r'(^|[^a-z0-9])x([^a-z0-9]|$)').hasMatch(lower)) {
    return 'X';
  }
  return null;
}

Color libraryPlatformColor(String name) {
  switch (name) {
    case 'TikTok':
      return const Color(0xFF00F2FE);
    case 'YouTube':
      return const Color(0xFFFF0000);
    case 'Instagram':
      return const Color(0xFFE1306C);
    case 'Facebook':
      return const Color(0xFF1877F2);
    case 'Reddit':
      return const Color(0xFFFF4500);
    case 'Pinterest':
      return const Color(0xFFE60023);
    default:
      return Colors.white;
  }
}

/// Centered empty or error block used on the dark library page.
class LibraryEmpty extends StatelessWidget {
  const LibraryEmpty({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? LibraryLook.danger : LibraryLook.violet;
    final wash = danger ? LibraryLook.dangerDim : LibraryLook.violetDim;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: wash,
                  shape: BoxShape.circle,
                  border: Border.all(color: color.withValues(alpha: 0.4)),
                ),
                child: Icon(icon, size: 40, color: color),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: Color(0x99FFFFFF),
                ),
              ),
              if (action != null) ...[const SizedBox(height: 16), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Rounded dashed outline for a vault file that is no longer on disk.
class DashedRoundedBorder extends StatelessWidget {
  const DashedRoundedBorder({
    super.key,
    required this.child,
    this.color = LibraryLook.danger,
    this.radius = LibraryLook.radius,
  });

  final Widget child;
  final Color color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: _DashedRRectPainter(color: color, radius: radius),
      child: child,
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  _DashedRRectPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      );
    for (final metric in path.computeMetrics()) {
      var start = 0.0;
      while (start < metric.length) {
        final end = (start + 5).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(start, end), paint);
        start += 8;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
