import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/theme/app_colors.dart';
import 'package:social_save/features/library/device_media.dart';
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
  static const _rates = <double>[0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];

  late final Player _player;
  late final VideoController _video;
  final _subs = <StreamSubscription<dynamic>>[];

  String? _error;
  bool _ready = false;
  bool _inPip = false;
  bool _loop = false;
  bool _muted = false;
  bool _completed = false;
  bool _didResume = false;
  double _rate = 1;
  double _volume = 100;
  BoxFit _fit = BoxFit.contain;

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
    _subs.add(_player.stream.error.listen((message) {
      if (!mounted || message.trim().isEmpty) return;
      setState(() => _error = 'Playback error. Try Open in another app.');
    }));
    _subs.add(_player.stream.completed.listen((done) {
      if (!mounted) return;
      setState(() => _completed = done);
      if (done) unawaited(_clearResume());
    }));
    _subs.add(_player.stream.rate.listen((value) {
      if (mounted) setState(() => _rate = value);
    }));
    _subs.add(_player.stream.volume.listen((value) {
      if (!mounted) return;
      setState(() {
        _volume = value;
        _muted = value <= 0;
      });
    }));
    _subs.add(_player.stream.duration.listen((duration) {
      if (duration.inMilliseconds > 8000) {
        unawaited(_restoreResume());
      }
    }));
    PipController.listen((inPip) {
      if (mounted) setState(() => _inPip = inPip);
    });
    _open();
  }

  String? get _resumeKey {
    final path = widget.session.filePath;
    if (path == null || path.isEmpty) return null;
    return 'player.pos.${path.hashCode}';
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
        ...?session.httpHeaders,
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
      if (session.isVault) {
        await DeviceMediaService().setSecure(true);
        await PipController.setAllowed(false);
      } else {
        await PipController.setAllowed(true);
      }
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

  Future<void> _restoreResume() async {
    if (_didResume || widget.session.isPreview) return;
    final key = _resumeKey;
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(key);
    final duration = _player.state.duration.inMilliseconds;
    if (ms == null || ms < 5000 || duration <= 0 || ms > duration - 2000) {
      return;
    }
    _didResume = true;
    await _player.seek(Duration(milliseconds: ms));
  }

  Future<void> _saveResume() async {
    final key = _resumeKey;
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    final pos = _player.state.position.inMilliseconds;
    final duration = _player.state.duration.inMilliseconds;
    if (_completed || pos < 5000 || (duration > 0 && pos > duration - 2000)) {
      await prefs.remove(key);
      return;
    }
    await prefs.setInt(key, pos);
  }

  Future<void> _clearResume() async {
    final key = _resumeKey;
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }

  Future<void> _skip(int seconds) async {
    final next = _player.state.position + Duration(seconds: seconds);
    final duration = _player.state.duration;
    var target = next;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    await _player.seek(target);
  }

  Future<void> _setRate(double rate) async {
    await _player.setRate(rate);
    if (mounted) setState(() => _rate = rate);
  }

  Future<void> _toggleLoop() async {
    final next = !_loop;
    await _player.setPlaylistMode(
      next ? PlaylistMode.single : PlaylistMode.none,
    );
    if (mounted) setState(() => _loop = next);
  }

  Future<void> _toggleMute() async {
    if (_muted) {
      await _player.setVolume(_volume <= 0 ? 100 : _volume);
    } else {
      _volume = _player.state.volume;
      await _player.setVolume(0);
    }
  }

  void _cycleFit() {
    setState(() {
      _fit = _fit == BoxFit.contain ? BoxFit.cover : BoxFit.contain;
    });
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

  Future<void> _showTools() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF111827),
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: StatefulBuilder(
              builder: (context, setSheet) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Playback',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Double-tap sides to skip 10s. Hold to play at 2x. Drag right for volume, left for brightness.',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Speed',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final rate in _rates)
                          ChoiceChip(
                            label: Text(_rateLabel(rate)),
                            selected: (_rate - rate).abs() < 0.01,
                            onSelected: (_) {
                              unawaited(_setRate(rate));
                              setSheet(() {});
                            },
                          ),
                      ],
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _loop,
                      title: const Text(
                        'Loop this video',
                        style: TextStyle(color: Colors.white),
                      ),
                      onChanged: (_) async {
                        await _toggleLoop();
                        setSheet(() {});
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _fit == BoxFit.cover,
                      title: const Text(
                        'Fill the screen',
                        style: TextStyle(color: Colors.white),
                      ),
                      onChanged: (_) {
                        _cycleFit();
                        setSheet(() {});
                      },
                    ),
                    Row(
                      children: [
                        Icon(
                          _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                          color: Colors.white,
                        ),
                        Expanded(
                          child: Slider(
                            value: _muted ? 0 : _volume.clamp(0, 100),
                            max: 100,
                            onChanged: (value) {
                              unawaited(_player.setVolume(value));
                              setSheet(() {
                                _volume = value;
                                _muted = value <= 0;
                              });
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  String _rateLabel(double rate) {
    if (rate == rate.roundToDouble()) return '${rate.toStringAsFixed(0)}x';
    return '${rate}x';
  }

  MaterialVideoControlsThemeData _theme() {
    return MaterialVideoControlsThemeData(
      displaySeekBar: true,
      seekOnDoubleTap: true,
      seekGesture: true,
      volumeGesture: true,
      brightnessGesture: true,
      speedUpOnLongPress: true,
      speedUpFactor: 2,
      visibleOnMount: true,
      seekBarPositionColor: AppColors.secondaryContainer,
      seekBarThumbColor: AppColors.secondaryContainer,
      bottomButtonBarMargin: const EdgeInsets.only(left: 8, right: 8, bottom: 12),
      primaryButtonBar: [
        const Spacer(flex: 2),
        MaterialCustomButton(
          icon: const Icon(Icons.replay_10_rounded),
          onPressed: () => unawaited(_skip(-10)),
        ),
        const Spacer(),
        MaterialPlayOrPauseButton(iconSize: 56),
        const Spacer(),
        MaterialCustomButton(
          icon: const Icon(Icons.forward_10_rounded),
          onPressed: () => unawaited(_skip(10)),
        ),
        const Spacer(flex: 2),
      ],
      bottomButtonBar: [
        const MaterialPositionIndicator(),
        const Spacer(),
        MaterialCustomButton(
          icon: Text(
            _rateLabel(_rate),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
          onPressed: () => unawaited(_showTools()),
        ),
        MaterialCustomButton(
          icon: Icon(_loop ? Icons.repeat_one_rounded : Icons.repeat_rounded),
          onPressed: () => unawaited(_toggleLoop()),
        ),
        MaterialCustomButton(
          icon: Icon(_muted ? Icons.volume_off_rounded : Icons.volume_up_rounded),
          onPressed: () => unawaited(_toggleMute()),
        ),
        MaterialCustomButton(
          icon: Icon(
            _fit == BoxFit.cover
                ? Icons.fit_screen_rounded
                : Icons.aspect_ratio_rounded,
          ),
          onPressed: _cycleFit,
        ),
        const MaterialFullscreenButton(),
      ],
    );
  }

  @override
  void dispose() {
    unawaited(_saveResume());
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    PipController.setAllowed(false);
    PipController.clearListener();
    WakelockPlus.disable();
    DeviceMediaService().setSecure(false);
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = _theme();
    final video = MaterialVideoControlsTheme(
      normal: theme,
      fullscreen: theme.copyWith(
        bottomButtonBarMargin: const EdgeInsets.only(left: 8, right: 8, bottom: 24),
      ),
      child: Video(
        controller: _video,
        fill: Colors.black,
        fit: _fit,
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
                        Text(
                          widget.session.isPreview
                              ? 'Preview · not saved yet'
                              : widget.session.isVault
                                  ? 'Vault · PIN protected'
                                  : 'Tap video for skip, speed, loop, and fill',
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Playback options',
                    onPressed: _showTools,
                    icon: const Icon(Icons.tune_rounded, color: Colors.white),
                  ),
                  if (!widget.session.isVault)
                    IconButton(
                      tooltip: 'Play over other apps',
                      onPressed: _playOverApps,
                      icon: const Icon(Icons.picture_in_picture_alt_rounded, color: Colors.white),
                    ),
                  if (widget.session.filePath != null && !widget.session.isVault)
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
                            if (widget.session.filePath != null && !widget.session.isVault) ...[
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
