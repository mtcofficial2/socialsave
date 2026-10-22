import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
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
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const PopScope(canPop: false, child: _PrepProgressDialog()),
  ));
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
  if (context.mounted) {
    Navigator.of(context, rootNavigator: true).pop();
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

/// Shows real progress and the time left while the phone rewrites the video.
class _PrepProgressDialog extends StatefulWidget {
  const _PrepProgressDialog();

  @override
  State<_PrepProgressDialog> createState() => _PrepProgressDialogState();
}

class _PrepProgressDialogState extends State<_PrepProgressDialog> {
  Timer? _poll;
  double _fraction = -1;
  int _etaMs = -1;
  String _stage = 'Checking the video';

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(milliseconds: 400), (_) async {
      final p = await MediaStoreService().uploadPrepProgress();
      if (!mounted) return;
      setState(() {
        final f = (p['fraction'] as num?)?.toDouble() ?? -1;
        if (f > _fraction) _fraction = f;
        _etaMs = (p['etaMs'] as num?)?.toInt() ?? -1;
        final stage = p['stage'] as String?;
        if (stage != null && stage.isNotEmpty) _stage = stage;
      });
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  String get _left {
    if (_etaMs < 0) return '';
    final s = (_etaMs / 1000).ceil();
    if (s < 2) return 'Almost done';
    if (s < 60) return 'About $s s left';
    return 'About ${(s / 60).ceil()} min left';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final known = _fraction >= 0;
    return AlertDialog(
      title: const Text('Making a file TikTok can open'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 8,
              value: known ? _fraction.clamp(0.0, 1.0) : null,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            known ? '$_stage · ${(_fraction * 100).round()}%' : _stage,
            style: TextStyle(color: scheme.onSurface, fontWeight: FontWeight.w600),
          ),
          if (_left.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_left, style: TextStyle(color: scheme.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }
}