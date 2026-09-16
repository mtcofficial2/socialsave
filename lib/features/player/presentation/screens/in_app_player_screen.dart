import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:open_filex/open_filex.dart';
import 'package:social_save/core/theme/app_colors.dart';
import 'package:social_save/features/player/pip.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/shared/widgets/platform_logo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class InAppPlayerScreen extends StatefulWidget {
  const InAppPlayerScreen({super.key, required this.session});

  final PlayerSession session;

  @override
  State<InAppPlayerScreen> createState() => _InAppPlayerScreenState();
}

class _InAppPlayerScreenState extends State<InAppPlayerScreen> {
  late final Player _player;
  late final VideoController _video;
  String? _error;
  bool _ready = false;
  bool _inPip = false;

  @override
  void initState() {
    super.initState();
    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 64 * 1024 * 1024,
        title: 'SocialSave',
      ),
    );
    _video = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );
    _player.stream.error.listen((message) {
      if (!mounted || message.trim().isEmpty) return;
      setState(() => _error = 'Playback error. Try Open in another app.');
    });
    PipController.listen((inPip) {
      if (mounted) setState(() => _inPip = inPip);
    });
    _open();
  }

  Future<void> _open() async {
    final session = widget.session;
    String? uri;
    Map<String, String>? headers;
    if (session.filePath != null && File(session.filePath!).existsSync()) {
      uri = session.filePath;
    } else if (session.networkUrl != null && session.networkUrl!.isNotEmpty) {
      uri = session.networkUrl;
      headers = {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/126.0.0.0 Mobile Safari/537.36',
        'Accept': '*/*',
        if (session.referer != null) 'Referer': session.referer!,
      };
    }
    if (uri == null) {
      setState(() => _error = 'Nothing to play.');
      return;
    }
    try {
      await _player.open(Media(uri, httpHeaders: headers));
      await _player.play();
      await WakelockPlus.enable();
      await PipController.setAllowed(true);
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = session.isPreview
              ? 'This preview stream is not playable. Download the file, then play it.'
              : 'Could not play this file in SocialSave.';
        });
      }
    }
  }

  Future<void> _openExternal() async {
    final path = widget.session.filePath;
    if (path == null || !File(path).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Download the video first to open it in another app.'),
          ),
        );
      }
      return;
    }
    await OpenFilex.open(path, type: 'video/*');
  }

  Future<void> _playOverApps() async {
    final ok = await PipController.enter();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This device cannot play over other apps.')),
      );
    }
  }

  @override
  void dispose() {
    PipController.setAllowed(false);
    PipController.clearListener();
    WakelockPlus.disable();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = MaterialVideoControlsTheme(
      normal: const MaterialVideoControlsThemeData(
        seekBarPositionColor: AppColors.secondaryContainer,
        seekBarThumbColor: AppColors.secondaryContainer,
        bottomButtonBarMargin: EdgeInsets.only(bottom: 16),
      ),
      fullscreen: const MaterialVideoControlsThemeData(
        seekBarPositionColor: AppColors.secondaryContainer,
        seekBarThumbColor: AppColors.secondaryContainer,
      ),
      child: Video(
        controller: _video,
        fill: Colors.black,
        controls: _inPip ? null : MaterialVideoControls,
      ),
    );

    if (_inPip) {
      return Scaffold(backgroundColor: Colors.black, body: video);
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                  ),
                  PlatformLogo(platform: widget.session.platform, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.session.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        if (widget.session.isPreview)
                          const Text(
                            'Preview · not saved yet',
                            style: TextStyle(color: Colors.white70, fontSize: 11),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Play over other apps',
                    onPressed: _playOverApps,
                    icon: const Icon(Icons.picture_in_picture_alt_rounded, color: Colors.white),
                  ),
                  if (widget.session.filePath != null)
                    IconButton(
                      tooltip: 'Open in another app',
                      onPressed: _openExternal,
                      icon: const Icon(Icons.open_in_new_rounded, color: Colors.white),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 16,
                                height: 1.4,
                              ),
                            ),
                            if (widget.session.filePath != null) ...[
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: _openExternal,
                                child: const Text('Open in another app'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  : video,
            ),
            if (!_ready && _error == null)
              const LinearProgressIndicator(
                color: AppColors.secondaryContainer,
                backgroundColor: Colors.white10,
              ),
          ],
        ),
      ),
    );
  }
}
