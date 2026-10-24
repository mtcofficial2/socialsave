import 'dart:async';
import 'dart:io';

import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:social_save/shared/widgets/premium_glass.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/core/storage/media_store_service.dart';

const _videoExts = {'mp4', 'm4v', 'mov', 'mkv', 'webm'};

const _exportDests = <(String, String, String)>[
  ('tiktok', 'TikTok', 'Fits the picture in 1080p. Portrait stays portrait. 30 fps, sound kept.'),
  ('reels', 'Reels', 'A portrait 1080×1920 canvas. Landscape is letterboxed, not cropped.'),
  ('shorts', 'Shorts', 'A portrait 1080×1920 canvas. Landscape is letterboxed, not cropped.'),
  ('x', 'X', 'Fits the picture in 1080p, the same way TikTok does. Sound stays.'),
];

/// Rewrites a saved video for TikTok, Reels, Shorts, or X.
/// The original download quality is unchanged until the person asks.
/// Returns true when the library list should refresh.
Future<bool> offerTiktokReady(
  BuildContext context, {
  required String path,
  required String title,
  String dest = '',
}) async {
  if (!Plat.isAndroid) {
    _note(context, 'Preparing a video for another app runs on the phone.');
    return false;
  }
  if (!File(path).existsSync()) {
    _note(context, 'That video is not on this phone.');
    return false;
  }
  final ext = path.split('.').last.toLowerCase();
  if (!_videoExts.contains(ext)) {
    _note(context, 'This kind of file cannot be prepared.');
    return false;
  }
  var chosen = dest;
  if (chosen.isEmpty) {
    if (!context.mounted) return false;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Prepare for another app'),
              subtitle: Text('The saved file stays until you pick one. This does not lower the download.'),
            ),
            for (final item in _exportDests)
              ListTile(
                title: Text(item.$2),
                subtitle: Text(item.$3),
                onTap: () => Navigator.pop(context, item.$1),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !context.mounted) return false;
    chosen = picked;
  }
  final label = _exportDests.firstWhere((item) => item.$1 == chosen, orElse: () => _exportDests.first).$2;
  var needs = false;
  try {
    needs = await MediaStoreService().needsTiktokWork(path, dest: chosen);
  } catch (_) {}
  if (!context.mounted) return false;
  if (!needs) {
    _note(context, '$label can already open this video.');
    return false;
  }
  final name = title.trim().isEmpty ? 'This video' : title.trim();
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Make this video work on $label?'),
      content: Text(
        '$name will be remade as 30 fps H.264 with the sound kept. The picture is fitted, not stretched or cropped. The file you downloaded stays until this finishes.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Keep this file'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Make it ready'),
        ),
      ],
    ),
  );
  if (yes != true || !context.mounted) return false;
  final close = showTiktokPrepProgress(context, label: label);
  await Future<void>.delayed(const Duration(milliseconds: 80));
  String? ready;
  try {
    ready = await MediaStoreService().makeUploadReady(path, dest: chosen);
  } catch (_) {
    ready = path;
  }
  final out = (ready == null || ready.isEmpty) ? path : ready;
  var stillNeeds = true;
  try {
    stillNeeds = await MediaStoreService().needsTiktokWork(out, dest: chosen);
  } catch (_) {}
  try {
    await MediaStoreService().scanFile(out);
  } catch (_) {}
  close();
  if (context.mounted) {
    _note(
      context,
      stillNeeds
          ? 'Could not rewrite it. The original file is still here.'
          : 'This video is ready for $label.',
    );
  }
  return true;
}

void _note(BuildContext context, String text) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// Opens the live export progress dialog. Call the result to close it.
VoidCallback showTiktokPrepProgress(BuildContext context, {String label = 'TikTok'}) {
  BuildContext? dialogCtx;
  var closed = false;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (c) {
      dialogCtx = c;
      return PopScope(canPop: false, child: TiktokPrepProgress(label: label));
    },
  ).whenComplete(() => closed = true));
  return () {
    final c = dialogCtx;
    if (closed || c == null || !c.mounted) return;
    closed = true;
    Navigator.of(c).pop();
  };
}

/// Live encoder progress: bar, percent, stage, speed and time left.
/// The native side reports the encoded frame time over the duration every
/// 250 ms; the bar eases toward it and never moves back.
class TiktokPrepProgress extends StatefulWidget {
  const TiktokPrepProgress({super.key, this.label = 'TikTok'});

  final String label;

  @override
  State<TiktokPrepProgress> createState() => _TiktokPrepProgressState();
}

class _TiktokPrepProgressState extends State<TiktokPrepProgress> with SingleTickerProviderStateMixin {
  Timer? _poll;
  late final Ticker _ticker;
  double _target = 0;
  double _shown = 0;
  bool _known = false;
  int _etaMs = -1;
  double _speed = 0;
  bool _repack = false;
  String _stage = 'Checking video';

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      if (_shown >= _target) return;
      // Ease 12% of the gap per frame, at least 0.1%, never past the target.
      final next = math.min(_target, _shown + math.max(0.001, (_target - _shown) * 0.12));
      setState(() => _shown = next);
    })..start();
    _poll = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      Map<dynamic, dynamic> p;
      try {
        p = await MediaStoreService().uploadPrepProgress();
      } catch (_) {
        return;
      }
      if (!mounted) return;
      setState(() {
        final f = (p['fraction'] as num?)?.toDouble() ?? -1;
        if (f >= 0) {
          _known = true;
          if (f > _target) _target = f;
        }
        _etaMs = (p['etaMs'] as num?)?.toInt() ?? -1;
        _speed = (p['speed'] as num?)?.toDouble() ?? 0;
        _repack = p['repack'] == true;
        final stage = p['stage'] as String?;
        if (stage != null && stage.isNotEmpty) _stage = stage;
        // A repack has no frame clock; creep toward 90% so it never sits still.
        if (_repack && _target < 0.9) _target = math.min(0.9, _target + 0.04);
      });
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  String get _left {
    if (_etaMs < 0 || _repack) return '';
    final s = (_etaMs / 1000).ceil();
    if (s < 2) return 'Almost done';
    if (s < 60) return '${s}s left';
    return '${s ~/ 60}m ${s % 60}s left';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pct = (_shown * 100).floor().clamp(0, 100);
    final info = [
      if (_speed > 0.05) '${_speed.toStringAsFixed(1)}x',
      if (_left.isNotEmpty) _left,
    ].join('  ·  ');
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28),
      child: PremiumGlass(
        level: GlassLevel.thick,
        radius: 28,
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_repack ? Icons.check_circle_rounded : Icons.auto_awesome_rounded, color: scheme.primary, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(_repack ? 'Already ${widget.label}-ready' : 'Making it ${widget.label}-ready',
                      style: theme.textTheme.titleMedium?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w600)),
                ),
                Text('$pct%',
                    style: theme.textTheme.titleMedium?.copyWith(
                        color: scheme.onSurface, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                minHeight: 8,
                value: _known ? _shown.clamp(0.0, 1.0) : null,
                backgroundColor: scheme.onSurface.withValues(alpha: 0.10),
              ),
            ),
            const SizedBox(height: 12),
            Text(_repack ? 'Repacking, no conversion needed' : _stage,
                style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface)),
            if (info.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(info, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ),
          ],
        ),
      ),
    );
  }
}
