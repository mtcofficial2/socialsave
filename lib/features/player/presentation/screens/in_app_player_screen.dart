import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/theme/app_colors.dart';
import 'package:social_save/features/library/device_media.dart';
import 'package:social_save/features/player/pip.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/widgets/platform_logo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class InAppPlayerScreen extends ConsumerStatefulWidget {
  const InAppPlayerScreen({super.key, required this.session});

  final PlayerSession session;

  @override
  ConsumerState<InAppPlayerScreen> createState() => _InAppPlayerScreenState();
}

class _InAppPlayerScreenState extends ConsumerState<InAppPlayerScreen> {
  static const _rates = <double>[0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];

  late final Player _player;
  late final VideoController _video;
  final _subs = <StreamSubscription<dynamic>>[];

  String? _error;
  bool _ready = false;
  bool _chrome = true;
  bool _inPip = false;
  Timer? _chromeTimer;
  Timer? _sleepTimer;
  int? _sleepMinutes;
  bool _loop = false;
  bool _muted = false;
  bool _completed = false;
  bool _didResume = false;
  double _rate = 1;
  double _volume = 100;
  BoxFit _fit = BoxFit.contain;
  bool _pinchZoom = false;
  int? _frameWidth;
  int? _frameHeight;
  Duration? _markA;
  Duration? _markB;
  bool _loopAB = false;
  bool _showEndCard = false;
  int _countdown = 5;
  Timer? _nextTimer;
  late List<PlayerQueueItem> _queue;
  late int _queueIndex;

  PlayerSession get _session {
    if (_queue.isEmpty) return widget.session;
    return _queue[_queueIndex.clamp(0, _queue.length - 1)].toSession();
  }

  bool get _hasNext => _queueIndex < _queue.length - 1;

  @override
  void initState() {
    super.initState();
    _queue = List<PlayerQueueItem>.from(widget.session.queue);
    _queueIndex = widget.session.queueIndex;
    if (_queue.isEmpty) {
      _queue = [
        PlayerQueueItem(
          title: widget.session.title,
          filePath: widget.session.filePath,
          networkUrl: widget.session.networkUrl,
          httpHeaders: widget.session.httpHeaders,
          referer: widget.session.referer,
          platform: widget.session.platform,
          isVault: widget.session.isVault,
        ),
      ];
      _queueIndex = 0;
    }
    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 64 * 1024 * 1024,
        title: 'SocialSave',
      ),
    );
    _video = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        // YouTube files are often AV1 or VP9. Hardware decode fails on many phones.
        enableHardwareAcceleration: false,
      ),
    );
    _subs.add(_player.stream.error.listen((message) {
      if (!mounted || message.trim().isEmpty) return;
      setState(() => _error = 'Playback error. Try Open in another app.');
    }));
    _subs.add(_player.stream.completed.listen((done) {
      if (!mounted) return;
      setState(() => _completed = done);
      if (done) {
        unawaited(_clearResume());
        unawaited(_onFinished());
      }
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
    _subs.add(_player.stream.width.listen((value) {
      if (!mounted || value == null || value <= 0) return;
      setState(() => _frameWidth = value);
      _syncPipAspect();
    }));
    _subs.add(_player.stream.height.listen((value) {
      if (!mounted || value == null || value <= 0) return;
      setState(() => _frameHeight = value);
      _syncPipAspect();
    }));
    _subs.add(_player.stream.position.listen((pos) {
      final a = _markA;
      final b = _markB;
      if (a == null || b == null || !_loopAB) return;
      if (pos >= b) {
        unawaited(_player.seek(a));
      }
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
    _showChrome();
  }

  void _showChrome() {
    _chromeTimer?.cancel();
    if (mounted && !_chrome) {
      setState(() => _chrome = true);
    } else {
      _chrome = true;
    }
    _chromeTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || _showEndCard) return;
      setState(() => _chrome = false);
    });
  }

  void _setSleep(int minutes) {
    _sleepTimer?.cancel();
    setState(() => _sleepMinutes = minutes);
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      if (!mounted) return;
      unawaited(_player.pause());
      setState(() => _sleepMinutes = null);
    });
  }

  String? get _resumeKey {
    final path = _session.filePath;
    if (path == null || path.isEmpty) return null;
    return 'player.pos.${path.hashCode}';
  }

  Future<void> _open() async {
    final session = _session;
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
        ..._platformHeaders(session.platform),
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
    if (_didResume || _session.isPreview) return;
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

  void _toggleAB() {
    final pos = _player.state.position;
    setState(() {
      if (_markA == null) {
        _markA = pos;
        _loopAB = false;
      } else if (_markB == null || pos <= _markA!) {
        if (pos <= _markA!) {
          _markA = pos;
        } else {
          _markB = pos;
          _loopAB = true;
        }
      } else {
        _markA = null;
        _markB = null;
        _loopAB = false;
      }
    });
  }

  Future<void> _jumpToTime() async {
    final pos = _player.state.position;
    final controller = TextEditingController(
      text: '${pos.inMinutes}:${(pos.inSeconds % 60).toString().padLeft(2, '0')}',
    );
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Jump to time'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.datetime,
          decoration: const InputDecoration(hintText: 'm:ss or mm:ss'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Go'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    final parts = value.trim().split(RegExp(r'[:.]'));
    if (parts.isEmpty) return;
    final seconds = parts.length == 1
        ? int.tryParse(parts[0]) ?? 0
        : (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts.last) ?? 0);
    await _player.seek(Duration(seconds: seconds));
  }

  Future<void> _saveFrame() async {
    final bytes = await _player.screenshot();
    if (bytes == null || !mounted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not capture this frame.')),
        );
      }
      return;
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/frame_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await file.writeAsBytes(bytes);
    await Share.shareXFiles([XFile(file.path)], text: _session.title);
  }

  Future<void> _openExternal() async {
    final path = _session.filePath;
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

  void _syncPipAspect() {
    final width = _frameWidth;
    final height = _frameHeight;
    if (width == null || height == null) return;
    unawaited(PipController.setAspect(width, height));
  }

  Future<void> _playOverApps() async {
    _syncPipAspect();
    final ok = await PipController.enter();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This device cannot play over other apps.')),
      );
    }
  }

  void _cancelCountdown() {
    _nextTimer?.cancel();
    _nextTimer = null;
  }

  Future<void> _onFinished() async {
    if (_loop || _showEndCard) return;
    final autoNext = ref.read(settingsControllerProvider).autoPlayNextInGallery;
    setState(() {
      _showEndCard = true;
      _countdown = 5;
    });
    if (!autoNext || !_hasNext) return;
    _nextTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_countdown <= 1) {
        timer.cancel();
        unawaited(_playNext());
        return;
      }
      setState(() => _countdown -= 1);
    });
  }

  Future<void> _rewatch() async {
    _cancelCountdown();
    if (mounted) {
      setState(() {
        _showEndCard = false;
        _completed = false;
      });
    }
    await _player.seek(Duration.zero);
    await _player.play();
  }

  Future<void> _playNext() async {
    if (!_hasNext) return;
    HapticFeedback.lightImpact();
    _cancelCountdown();
    setState(() {
      _queueIndex += 1;
      _showEndCard = false;
      _completed = false;
      _ready = false;
      _error = null;
      _didResume = true;
      _frameWidth = null;
      _frameHeight = null;
      _markA = null;
      _markB = null;
      _loopAB = false;
    });
    var item = _queue[_queueIndex];
    final existing = item.filePath;
    if (existing == null || !File(existing).existsSync()) {
      if (item.deviceId != null) {
        final path = await DeviceMediaService().resolvePlayablePath(
          DeviceVideo(
            id: item.deviceId!,
            title: item.title,
            path: item.devicePath,
            uri: item.deviceUri,
          ),
        );
        if (path != null) {
          item = item.copyWith(filePath: path);
          _queue[_queueIndex] = item;
        }
      }
    }
    if (!mounted) return;
    await _open();
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
                      'Sleep timer',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final minutes in [15, 30, 45])
                          ChoiceChip(
                            label: Text('$minutes min'),
                            selected: _sleepMinutes == minutes,
                            onSelected: (_) {
                              _setSleep(minutes);
                              setSheet(() {});
                            },
                          ),
                      ],
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
                      value: _pinchZoom,
                      title: const Text(
                        'Pinch to zoom',
                        style: TextStyle(color: Colors.white),
                      ),
                      subtitle: const Text(
                        'Turn off to keep skip, seek, and volume gestures.',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      onChanged: (value) {
                        setState(() => _pinchZoom = value);
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
                      subtitle: const Text(
                        'Off keeps the real video shape. On fills the window.',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      onChanged: (_) {
                        _cycleFit();
                        setSheet(() {});
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.timelapse_rounded, color: Colors.white70),
                      title: const Text('Jump to time', style: TextStyle(color: Colors.white)),
                      onTap: () {
                        Navigator.pop(context);
                        unawaited(_jumpToTime());
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.camera_alt_outlined, color: Colors.white70),
                      title: const Text('Save a still frame', style: TextStyle(color: Colors.white)),
                      onTap: () {
                        Navigator.pop(context);
                        unawaited(_saveFrame());
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.repeat_on_rounded, color: Colors.white70),
                      title: Text(
                        _loopAB ? 'A–B loop on' : 'Set A–B loop',
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        _loopAB
                            ? 'Playing between the two marks'
                            : 'Mark this moment as A, then again as B',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      onTap: () {
                        _toggleAB();
                        setSheet(() {});
                      },
                    ),
                    if (_player.state.tracks.audio.length > 1) ...[
                      const Text('Audio', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final track in _player.state.tracks.audio)
                            ChoiceChip(
                              label: Text(track.title ?? track.language ?? track.id),
                              selected: _player.state.track.audio.id == track.id,
                              onSelected: (_) {
                                unawaited(_player.setAudioTrack(track));
                                setSheet(() {});
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_player.state.tracks.subtitle.isNotEmpty) ...[
                      const Text('Captions', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        children: [
                          ChoiceChip(
                            label: const Text('Off'),
                            selected: _player.state.track.subtitle.id == 'no',
                            onSelected: (_) {
                              unawaited(_player.setSubtitleTrack(SubtitleTrack.no()));
                              setSheet(() {});
                            },
                          ),
                          for (final track in _player.state.tracks.subtitle)
                            ChoiceChip(
                              label: Text(track.title ?? track.language ?? track.id),
                              selected: _player.state.track.subtitle.id == track.id,
                              onSelected: (_) {
                                unawaited(_player.setSubtitleTrack(track));
                                setSheet(() {});
                              },
                            ),
                        ],
                      ),
                    ],
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
        if (_hasNext)
          MaterialCustomButton(
            icon: const Icon(Icons.skip_next_rounded),
            onPressed: () => unawaited(_playNext()),
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
    _cancelCountdown();
    _chromeTimer?.cancel();
    _sleepTimer?.cancel();
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
      return Scaffold(
        backgroundColor: Colors.black,
        body: _FittedVideo(
          width: _frameWidth,
          height: _frameHeight,
          child: Video(
            controller: _video,
            fill: Colors.black,
            fit: BoxFit.contain,
            controls: null,
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Listener(
        onPointerDown: (_) => _showChrome(),
        child: SafeArea(
        child: Column(
          children: [
            if (_chrome || _showEndCard)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.maybePop(context),
                    icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                  ),
                  PlatformLogo(platform: _session.platform, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _session.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        Text(
                          _session.isPreview
                              ? 'Preview · not saved yet'
                              : _session.isVault
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
                  if (!_session.isVault)
                    IconButton(
                      tooltip: 'Play over other apps',
                      onPressed: _playOverApps,
                      icon: const Icon(Icons.picture_in_picture_alt_rounded, color: Colors.white),
                    ),
                  if (_session.filePath != null && !_session.isVault)
                    IconButton(
                      tooltip: 'Open in another app',
                      onPressed: _openExternal,
                      icon: const Icon(Icons.open_in_new_rounded, color: Colors.white),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (_error != null)
                    Center(
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
                            if (_session.filePath != null && !_session.isVault) ...[
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
                  else
                    _FittedVideo(
                      width: _frameWidth,
                      height: _frameHeight,
                      child: _pinchZoom
                          ? InteractiveViewer(
                              minScale: 1,
                              maxScale: 3,
                              panEnabled: false,
                              child: video,
                            )
                          : video,
                    ),
                  if (_showEndCard) _EndCard(
                    countdown: _countdown,
                    hasNext: _hasNext,
                    nextTitle: _hasNext ? _queue[_queueIndex + 1].title : null,
                    autoNext: ref.watch(settingsControllerProvider).autoPlayNextInGallery,
                    onRewatch: () => unawaited(_rewatch()),
                    onPlayNext: _hasNext ? () => unawaited(_playNext()) : null,
                  ),
                ],
              ),
            ),
            if (!_ready && _error == null)
              const LinearProgressIndicator(
                color: AppColors.secondaryContainer,
                backgroundColor: Colors.white10,
              ),
          ],
        ),
        ),
      ),
    );
  }
}

class _FittedVideo extends StatelessWidget {
  const _FittedVideo({
    required this.child,
    this.width,
    this.height,
  });

  final Widget child;
  final int? width;
  final int? height;

  @override
  Widget build(BuildContext context) {
    final frameWidth = width ?? 0;
    final frameHeight = height ?? 0;
    final aspect = frameWidth > 0 && frameHeight > 0
        ? frameWidth / frameHeight
        : 9 / 16;
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: AspectRatio(
          aspectRatio: aspect,
          child: child,
        ),
      ),
    );
  }
}

class _EndCard extends StatelessWidget {
  const _EndCard({
    required this.countdown,
    required this.hasNext,
    required this.autoNext,
    required this.onRewatch,
    this.nextTitle,
    this.onPlayNext,
  });

  final int countdown;
  final bool hasNext;
  final bool autoNext;
  final String? nextTitle;
  final VoidCallback onRewatch;
  final VoidCallback? onPlayNext;

  @override
  Widget build(BuildContext context) {
    final showTimer = autoNext && hasNext;
    return ColoredBox(
      color: const Color(0xCC000000),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.replay_rounded, color: Colors.white, size: 40),
              const SizedBox(height: 12),
              const Text(
                'Video ended',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 20,
                ),
              ),
              if (showTimer) ...[
                const SizedBox(height: 8),
                Text(
                  'Next in $countdown s',
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                ),
                if (nextTitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      nextTitle!,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
              ] else if (!hasNext)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'That was the last video in this list.',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: onRewatch,
                icon: const Icon(Icons.replay_rounded),
                label: const Text('Rewatch'),
              ),
              if (showTimer && onPlayNext != null) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: onPlayNext,
                  child: const Text(
                    'Play next now',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

Map<String, String> _platformHeaders(SocialPlatform platform) {
  switch (platform) {
    case SocialPlatform.facebook:
      return {
        'Referer': 'https://www.facebook.com/',
        'Origin': 'https://www.facebook.com',
      };
    case SocialPlatform.instagram:
      return {
        'Referer': 'https://www.instagram.com/',
        'Origin': 'https://www.instagram.com',
      };
    case SocialPlatform.youtube:
      return {
        'Referer': 'https://www.youtube.com/',
        'Origin': 'https://www.youtube.com',
      };
    default:
      return const {};
  }
}
