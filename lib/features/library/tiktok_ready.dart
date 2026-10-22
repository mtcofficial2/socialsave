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

/// Rewrites a video that is already on the phone so TikTok can open it.
/// Returns true when the library list should refresh.
Future<bool> offerTiktokReady(
  BuildContext context, {
  required String path,
  required String title,
}) async {
  if (!Plat.isAndroid) {
    _note(context, 'Preparing a video for TikTok runs on the phone.');
    return false;
  }
  if (!File(path).existsSync()) {
    _note(context, 'That video is not on this phone.');
    return false;
  }
  final ext = path.split('.').last.toLowerCase();
  if (!_videoExts.contains(ext)) {
    _note(context, 'This kind of file cannot be prepared for TikTok.');
    return false;
  }
  var needs = false;
  try {
    needs = await MediaStoreService().needsTiktokWork(path);
  } catch (_) {}
  if (!context.mounted) return false;
  if (!needs) {
    _note(context, 'TikTok can already open this video.');
    return false;
  }
  final name = title.trim().isEmpty ? 'This video' : title.trim();
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Make this video work on TikTok?'),
      content: Text(
        '$name is a kind of video TikTok may not open. Social Save can remake it as 30 fps H.264, fitted to 1080p without stretching. Portrait stays portrait.',
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
  final close = showTiktokPrepProgress(context);
  await Future<void>.delayed(const Duration(milliseconds: 80));
  String? ready;
  try {
    ready = await MediaStoreService().makeUploadReady(path);
  } catch (_) {
    ready = path;
  }
  final out = (ready == null || ready.isEmpty) ? path : ready;
  var stillNeeds = true;
  try {
    stillNeeds = await MediaStoreService().needsTiktokWork(out);
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
          : 'This video is ready for TikTok.',
    );
  }
  return true;
}

void _note(BuildContext context, String text) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

/// Opens the live TikTok-ready progress dialog. Call the result to close it.
VoidCallback showTiktokPrepProgress(BuildContext context) {
  BuildContext? dialogCtx;
  var closed = false;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (c) {
      dialogCtx = c;
      return const PopScope(canPop: false, child: TiktokPrepProgress());
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
  const TiktokPrepProgress({super.key});

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
                  child: Text(_repack ? 'Already TikTok-ready' : 'Making it TikTok-ready',
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
            Text(_repack && _stage == 'Already TikTok-ready' ? 'Repacking, no conversion needed' : _stage,
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
