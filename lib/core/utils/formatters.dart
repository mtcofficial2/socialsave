import 'package:intl/intl.dart';

class Formatters {
  const Formatters();

  String bytes(int? value) {
    if (value == null || value < 0) {
      return 'Unknown size';
    }
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = value.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    final digits = unit == 0 ? 0 : (size >= 10 ? 1 : 2);
    return '${size.toStringAsFixed(digits)} ${units[unit]}';
  }

  String speed(double bytesPerSecond) {
    if (bytesPerSecond <= 0) {
      return '—';
    }
    return '${bytes(bytesPerSecond.round())}/s';
  }

  String duration(int? totalSeconds) {
    if (totalSeconds == null || totalSeconds < 0) {
      return '--:--';
    }
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$mm:$ss';
    }
    return '$mm:$ss';
  }

  String eta(Duration? remaining) {
    if (remaining == null || remaining.inSeconds <= 0) {
      return '—';
    }
    if (remaining.inHours >= 1) {
      return '${remaining.inHours}h ${remaining.inMinutes.remainder(60)}m';
    }
    if (remaining.inMinutes >= 1) {
      return '${remaining.inMinutes}m ${remaining.inSeconds.remainder(60)}s';
    }
    return '${remaining.inSeconds}s';
  }

  String percent(double progress) {
    final clamped = progress.clamp(0, 1);
    return '${(clamped * 100).floor()}%';
  }

  String date(DateTime value) {
    return DateFormat.yMMMd().add_jm().format(value.toLocal());
  }

  String relativeDate(DateTime value, {DateTime? now}) {
    final current = now ?? DateTime.now();
    final delta = current.difference(value);
    if (delta.inMinutes < 1) {
      return 'Just now';
    }
    if (delta.inHours < 1) {
      return '${delta.inMinutes} min ago';
    }
    if (delta.inHours < 24) {
      return '${delta.inHours}h ago';
    }
    if (delta.inDays < 7) {
      return '${delta.inDays}d ago';
    }
    return DateFormat.MMMd().format(value.toLocal());
  }
}
