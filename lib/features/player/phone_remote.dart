import 'dart:async';

import 'package:flutter/material.dart';
import 'package:social_save/core/platform/phone_body.dart';
import 'package:social_save/features/player/playback_bridge.dart';

/// Shown on the phone while a video is also on a monitor or TV display.
class PhoneRemote extends StatefulWidget {
  const PhoneRemote({super.key});

  @override
  State<PhoneRemote> createState() => _PhoneRemoteState();
}

class _PhoneRemoteState extends State<PhoneRemote> {
  StreamSubscription<PhoneSnapshot>? _states;
  bool _show = false;

  @override
  void initState() {
    super.initState();
    PhoneBody.ensure();
    PlaybackBridge.attached.addListener(_refresh);
    _states = PhoneBody.snapshots.stream.listen((_) => _refresh());
    _refresh();
  }

  void _refresh() {
    final show = PhoneBody.latest.externalDisplay && PlaybackBridge.attached.value;
    if (mounted && show != _show) setState(() => _show = show);
  }

  @override
  void dispose() {
    PlaybackBridge.attached.removeListener(_refresh);
    unawaited(_states?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final title = PlaybackBridge.title?.call() ?? 'Video';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            children: [
              const Icon(Icons.tv_rounded),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: 'Back 10 seconds',
                onPressed: () => PlaybackBridge.seek?.call(-10),
                icon: const Icon(Icons.replay_10_rounded),
              ),
              IconButton(
                tooltip: 'Play or pause',
                onPressed: () => PlaybackBridge.toggle?.call(),
                icon: Icon(
                  PlaybackBridge.playing?.call() == true
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                ),
              ),
              IconButton(
                tooltip: 'Forward 10 seconds',
                onPressed: () => PlaybackBridge.seek?.call(10),
                icon: const Icon(Icons.forward_10_rounded),
              ),
              IconButton(
                tooltip: 'Next video',
                onPressed: () => PlaybackBridge.next?.call(),
                icon: const Icon(Icons.skip_next_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
