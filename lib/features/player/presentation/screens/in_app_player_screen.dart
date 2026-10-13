import 'dart:async';
import 'dart:io';


import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:social_save/features/library/phone_handoff.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:open_filex/open_filex.dart';
import 'package:social_save/core/platform/desktop_support.dart';
import 'package:social_save/core/platform/win_focus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/platform/phone_body.dart';
import 'package:social_save/core/theme/app_colors.dart';
import 'package:social_save/features/library/device_media.dart';
import 'package:social_save/features/player/pip.dart';
import 'package:social_save/features/player/playback_bridge.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/features/player/resume_position.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/widgets/platform_logo.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class InAppPlayerScreen extends ConsumerStatefulWidget {
  static bool keyLog = false;

  /// Open (non-docked) players; the app-wide Esc = back is off meanwhile.
  static int openCount = 0;
  const InAppPlayerScreen({
    super.key,
    required this.session,
    this.embedded = false,
    this.onClose,
  });

  final PlayerSession session;
  final bool embedded;
  final VoidCallback? onClose;

  @override
  ConsumerState<InAppPlayerScreen> createState() => _InAppPlayerScreenState();
}

class _InAppPlayerScreenState extends ConsumerState<InAppPlayerScreen>
    with WidgetsBindingObserver {
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
  bool _sleepAtEnd = false;
  bool _dimmed = false;
  bool _pocketPaused = false;
  bool _loop = false;
  bool _muted = false;
  bool _completed = false;
  bool _announcedResume = false;
  bool _resumeLanded = false;
  int? _resumeTargetMs;
  DateTime? _resumeUntil;
  DateTime? _lastForceSeek;
  DateTime? _lastResumeSave;
  double _rate = 1;
  double _volume = 100;
  BoxFit _fit = BoxFit.contain;
  bool _pinchZoom = false;
  bool _locked = false;
  bool _lockHint = false;
  int? _frameWidth;
  int? _frameHeight;
  Duration? _markA;
  Duration? _markB;
  bool _loopAB = false;
  bool _showEndCard = false;
  int _countdown = 5;
  Timer? _nextTimer;
  late List<PlayerQueueItem> _queue;
  // Desktop keyboard / mouse.
  final GlobalKey<VideoState> _videoKey = GlobalKey<VideoState>();
  final FocusNode _keyFocus = FocusNode(debugLabel: 'player-keys');
  String? _osd;
  IconData? _osdIcon;
  bool _osdVisible = false;
  Timer? _osdTimer;
  // Our own full screen (same page, so the OSD and keys keep working).
  bool _fs = false;
  bool _forceLandscape = false;
  double _preMuteVolume = 100;
  // Pinch (phone): two pointers, distance at start.
  final Map<int, Offset> _touches = {};
  double? _pinchStartDist;
  DateTime? _lastClick;
  Offset? _lastClickPos;
  static const _mkChannel = MethodChannel('com.alexmercerind/media_kit_video');
  late int _queueIndex;

  PlayerSession get _session {
    if (_queue.isEmpty) return widget.session;
    return _queue[_queueIndex.clamp(0, _queue.length - 1)].toSession();
  }

  bool get _hasNext => _queueIndex < _queue.length - 1;

  String? get _heroTag {
    if (_queueIndex != widget.session.queueIndex) return null;
    return widget.session.heroTag;
  }

  Widget _hiddenControls(VideoState state) => const SizedBox.shrink();

  @override
  void initState() {
    super.initState();
    _queue = List<PlayerQueueItem>.from(widget.session.queue);
    _queueIndex = widget.session.queueIndex;
    WidgetsBinding.instance.addObserver(this);
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
      _nudgeResume();
    }));
    _subs.add(_player.stream.height.listen((value) {
      if (!mounted || value == null || value <= 0) return;
      setState(() => _frameHeight = value);
      _syncPipAspect();
    }));
    _subs.add(_player.stream.position.listen((pos) {
      final a = _markA;
      final b = _markB;
      if (a != null && b != null && _loopAB && pos >= b) {
        unawaited(_player.seek(a));
        return;
      }
      _guardResume(pos);
      _saveResumeThrottled();
    }));
    PipController.listen((inPip) {
      if (mounted) setState(() => _inPip = inPip);
    });
    _bindPhone();
    if (DesktopSupport.isWindows) {
      _keyMap = _desktopKeys();
      HardwareKeyboard.instance.addHandler(_onHardwareKey);
      if (!widget.embedded) InAppPlayerScreen.openCount++;
    }
    _open();
    _showChrome();
  }

  void _bindPhone() {
    PhoneBody.ensure();
    PlaybackBridge.bind(
      owner: this,
      title: () => _session.title,
      playing: () => _player.state.playing,
      toggle: () async {
        if (_player.state.playing) {
          await _player.pause();
        } else {
          await _player.play();
        }
      },
      seek: _skip,
      next: () async {
        if (_hasNext) await _playNext();
      },
    );
    _subs.add(PhoneBody.snapshots.stream.listen((snap) async {
      if (!mounted) return;
      final settings = ref.read(settingsControllerProvider);
      if (!settings.pocketPause) return;
      if (snap.pocket) {
        if (_player.state.playing) {
          _pocketPaused = true;
          await _player.pause();
        }
      } else if (_pocketPaused) {
        _pocketPaused = false;
        await _player.play();
      }
    }));
    _subs.add(PhoneBody.actions.stream.listen((action) async {
      if (!mounted) return;
      final settings = ref.read(settingsControllerProvider);
      if (action.name == 'toggle' && settings.headsetControls) {
        if (_player.state.playing) {
          await _player.pause();
        } else {
          await _player.play();
        }
      } else if (action.name == 'next' && settings.headsetControls) {
        if (_hasNext) await _playNext();
      } else if (action.name == 'seek' && settings.volumeKeysSeek) {
        await _skip(action.delta);
        _flash('${action.delta > 0 ? '+' : '−'}${action.delta.abs()} s',
            icon: action.delta > 0 ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded);
      } else if (action.name == 'play') {
        // Lock screen / media notification controls.
        await _player.play();
      } else if (action.name == 'pause') {
        await _player.pause();
      } else if (action.name == 'skip') {
        await _skip(action.delta);
        _pushSession();
      } else if (action.name == 'seekTo') {
        await _player.seek(Duration(milliseconds: action.delta));
        _pushSession();
      } else if (action.name == 'skipNext') {
        if (_hasNext) await _playNext();
      }
    }));
    _subs.add(_player.stream.playing.listen((playing) {
      _pushSession();
      if (_ready && mounted && !_completed) {
        _flash(playing ? 'Play' : 'Pause', icon: playing ? Icons.play_arrow_rounded : Icons.pause_rounded);
      }
    }));
    _subs.add(_player.stream.duration.listen((_) => _pushSession()));
  }

  /// Media session state for the lock screen and the background service.
  void _pushSession() {
    if (!mounted) return;
    final settings = ref.read(settingsControllerProvider);
    unawaited(PhoneBody.setPlayback(
      active: true,
      playing: _player.state.playing,
      title: _session.title,
      headset: settings.headsetControls,
      volumeSeek: settings.volumeKeysSeek,
      background: Platform.isAndroid && settings.backgroundPlay && !_session.isVault,
      positionMs: _player.state.position.inMilliseconds,
      durationMs: _player.state.duration.inMilliseconds,
    ));
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
    _sleepAtEnd = false;
    setState(() => _sleepMinutes = minutes);
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      unawaited(_fireSleep());
    });
  }

  void _setSleepAtEnd() {
    _sleepTimer?.cancel();
    setState(() {
      _sleepMinutes = null;
      _sleepAtEnd = true;
    });
  }

  void _clearSleep() {
    _sleepTimer?.cancel();
    _sleepAtEnd = false;
    final wasDimmed = _dimmed;
    _dimmed = false;
    if (wasDimmed) unawaited(PhoneBody.setBrightness(-1));
    if (mounted) setState(() => _sleepMinutes = null);
  }

  Future<void> _fireSleep() async {
    _sleepTimer?.cancel();
    _sleepAtEnd = false;
    await _player.pause();
    await PhoneBody.setBrightness(0.05);
    _dimmed = true;
    if (!mounted) return;
    setState(() => _sleepMinutes = null);
  }

  Future<void> _playOnTv() async {
    final path = _session.filePath;
    if (path == null || !File(path).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Save the video on this phone before playing it on a TV.')),
        );
      }
      return;
    }
    final ok = await PhoneBody.playOnTv(path: path, title: _session.title);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No TV app on this phone could open the video.')),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_saveResume());
    }
    // With "Keep playing when screen is off" turned off, stop when the app
    // leaves the screen (not in picture-in-picture).
    if (state == AppLifecycleState.paused &&
        Platform.isAndroid &&
        !_inPip &&
        !ref.read(settingsControllerProvider).backgroundPlay &&
        _player.state.playing) {
      unawaited(_player.pause());
    }
  }

  String? get _resumeKey {
    final item = _queue.isEmpty
        ? null
        : _queue[_queueIndex.clamp(0, _queue.length - 1)];
    return resumeStorageKey(
      isPreview: _session.isPreview,
      deviceId: item?.deviceId,
      filePath: _session.filePath ?? item?.filePath,
    );
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
      final start = await _savedStart();
      await _player.open(Media(uri, httpHeaders: headers));
      await _player.play();
      if (start != null) _armResume(start);
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

  Future<Duration?> _savedStart() async {
    final key = _resumeKey;
    if (key == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(key);
    final duration = _player.state.duration.inMilliseconds;
    if (!shouldResume(ms, duration)) return null;
    return Duration(milliseconds: ms!);
  }

  void _armResume(Duration target) {
    _resumeTargetMs = target.inMilliseconds;
    _resumeLanded = false;
    _announcedResume = false;
    _resumeUntil = DateTime.now().add(const Duration(seconds: 8));
    _nudgeResume();
  }

  void _nudgeResume() {
    final targetMs = _resumeTargetMs;
    if (targetMs == null || _resumeLanded) return;
    unawaited(_seekResume(Duration(milliseconds: targetMs)));
  }

  /// Android attaches the video surface and then seeks back to the start.
  /// Keep putting the playhead on the saved spot until that reset is done.
  void _guardResume(Duration pos) {
    final targetMs = _resumeTargetMs;
    if (targetMs == null) return;
    final target = Duration(milliseconds: targetMs);
    final duration = _player.state.duration;
    if (duration > const Duration(seconds: 8) &&
        !shouldResume(targetMs, duration.inMilliseconds)) {
      _resumeTargetMs = null;
      unawaited(_clearResume());
      return;
    }
    if (_atResume(pos, target)) {
      _resumeLanded = true;
      _announceResume(target);
      final expired = _resumeUntil != null && DateTime.now().isAfter(_resumeUntil!);
      if (expired) _resumeTargetMs = null;
      return;
    }
    final expired = _resumeUntil != null && DateTime.now().isAfter(_resumeUntil!);
    if (expired) {
      _resumeTargetMs = null;
      return;
    }
    final resetToStart = pos < const Duration(seconds: 1);
    if (_resumeLanded && !resetToStart) {
      _resumeTargetMs = null;
      return;
    }
    unawaited(_seekResume(target));
  }

  bool _atResume(Duration pos, Duration target) {
    return pos > const Duration(milliseconds: 400) &&
        pos >= target - const Duration(milliseconds: 1200) &&
        pos <= target + const Duration(seconds: 2);
  }

  Future<void> _seekResume(Duration target) async {
    final now = DateTime.now();
    if (_lastForceSeek != null &&
        now.difference(_lastForceSeek!) < const Duration(milliseconds: 350)) {
      return;
    }
    _lastForceSeek = now;
    await _player.seek(target);
  }

  void _announceResume(Duration position) {
    if (_announcedResume || !mounted) return;
    _announcedResume = true;
    final label = formatResumeClock(position);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Resumed at $label'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Start over',
          onPressed: () {
            _resumeTargetMs = null;
            _resumeLanded = true;
            unawaited(_clearResume());
            unawaited(_player.seek(Duration.zero));
          },
        ),
      ),
    );
  }

  void _saveResumeThrottled() {
    if (!_ready) return;
    final now = DateTime.now();
    if (_lastResumeSave != null &&
        now.difference(_lastResumeSave!) < const Duration(seconds: 3)) {
      return;
    }
    _lastResumeSave = now;
    unawaited(_saveResume());
  }

  Future<void> _saveResume() async {
    final key = _resumeKey;
    if (key == null || !_ready) return;
    final pos = _player.state.position.inMilliseconds;
    final duration = _player.state.duration.inMilliseconds;
    final target = _resumeTargetMs;
    if (target != null && !_resumeLanded) return;
    final prefs = await SharedPreferences.getInstance();
    final stored = positionToStore(
      positionMs: pos,
      durationMs: duration,
      completed: _completed,
    );
    if (stored == null) {
      if (pos < 1000 && !_completed) return;
      await prefs.remove(key);
      return;
    }
    await prefs.setInt(key, stored);
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
    // Bug fix: the volume stream overwrote the saved level with 0, so
    // unmuting always jumped to 100 %.
    if (_muted) {
      final back = _preMuteVolume <= 0 ? 100.0 : _preMuteVolume;
      await _player.setVolume(back);
      _flash('Volume ${back.round()}%', icon: Icons.volume_up_rounded);
    } else {
      _preMuteVolume = _player.state.volume;
      await _player.setVolume(0);
      _flash('Muted', icon: Icons.volume_off_rounded);
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
    if (DesktopSupport.isWindows) {
      await DesktopSupport.open(path);
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
    if (_sleepAtEnd) {
      await _fireSleep();
      return;
    }
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
    _resumeTargetMs = null;
    _resumeLanded = true;
    await _player.seek(Duration.zero);
    await _player.play();
  }

  void _flash(String text, {IconData? icon}) {
    _osdTimer?.cancel();
    if (mounted) {
      setState(() {
        _osd = text;
        _osdIcon = icon;
        _osdVisible = true;
      });
    }
    _osdTimer = Timer(const Duration(milliseconds: 1100), () {
      if (mounted) setState(() => _osdVisible = false);
    });
  }

  /// On-screen feedback drawn above the video (both platforms, also in
  /// full screen because full screen is this same page).
  Widget _osdLayer() {
    return IgnorePointer(
      child: Align(
        alignment: const Alignment(0, -0.45),
        child: AnimatedOpacity(
          opacity: _osdVisible && _osd != null ? 1 : 0,
          duration: Duration(milliseconds: _osdVisible ? 90 : 350),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.62),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_osdIcon != null) ...[
                    Icon(_osdIcon, color: Colors.white, size: 26),
                    const SizedBox(width: 10),
                  ],
                  Text(
                    _osd ?? '',
                    style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool get _landscapeVideo => (_frameWidth ?? 16) >= (_frameHeight ?? 9);

  Future<void> _toggleFs() => _setFs(!_fs);

  /// Win32 focus back on our Flutter view, then the player's focus node,
  /// again after the next frames (the window style change settles late).
  void _refocus() {
    WinFocus.focusSelf();
    _keyFocus.requestFocus();
    for (final ms in const [50, 250, 700]) {
      Future<void>.delayed(Duration(milliseconds: ms), () {
        if (!mounted) return;
        WinFocus.focusSelf();
        _keyFocus.requestFocus();
      });
    }
  }

  Future<void> _setFs(bool on) async {
    if (on == _fs || !mounted) return;
    if (widget.embedded && DesktopSupport.isWindows) {
      // Docked beside the Library: use the video's own full-screen page.
      final state = _videoKey.currentState;
      if (state != null) await state.toggleFullscreen();
      return;
    }
    setState(() => _fs = on);
    try {
      if (DesktopSupport.isWindows) {
        // Real window full screen (no title bar / taskbar); the plugin
        // restores the old size and position on exit.
        await _mkChannel.invokeMethod<void>(on ? 'Utils.EnterNativeFullscreen' : 'Utils.ExitNativeFullscreen');
      } else {
        await _applyOrientation();
      }
    } catch (_) {}
    if (on) _showChrome();
    _refocus();
    _flash(on ? 'Full screen' : 'Full screen off',
        icon: on ? Icons.fullscreen_rounded : Icons.fullscreen_exit_rounded);
  }

  /// Phone: landscape videos go landscape in full screen, portrait videos
  /// stay portrait; the rotate button flips it.
  Future<void> _applyOrientation() async {
    if (DesktopSupport.isWindows) return;
    if (_fs) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      final landscape = _forceLandscape || (_landscapeVideo && !_forcePortrait);
      await SystemChrome.setPreferredOrientations(landscape
          ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : const [DeviceOrientation.portraitUp]);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(_forceLandscape
          ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : const []);
    }
  }

  bool _forcePortrait = false;

  Future<void> _rotate() async {
    final landscapeNow = MediaQuery.orientationOf(context) == Orientation.landscape;
    setState(() {
      _forceLandscape = !landscapeNow;
      _forcePortrait = landscapeNow;
    });
    if (!_fs && !_forceLandscape) {
      await SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await SystemChrome.setPreferredOrientations(const []);
      return;
    }
    await _applyOrientation();
  }

  // Pointer bookkeeping shared by phone (pinch) and PC (focus, double-click,
  // right-click menu, wheel feedback).
  void _onPointerDown(PointerDownEvent e) {
    _showChrome();
    if (DesktopSupport.isWindows) {
      _keyFocus.requestFocus();
      if (e.kind == PointerDeviceKind.mouse && e.buttons == kSecondaryMouseButton) {
        unawaited(_contextMenu(e.position));
        return;
      }
      if (e.buttons == kPrimaryMouseButton) {
        final now = DateTime.now();
        final last = _lastClick;
        final pos = _lastClickPos;
        if (last != null && pos != null &&
            now.difference(last) < const Duration(milliseconds: 350) &&
            (e.position - pos).distance < 24) {
          _lastClick = null;
          unawaited(_toggleFs());
        } else {
          _lastClick = now;
          _lastClickPos = e.position;
        }
      }
      return;
    }
    _touches[e.pointer] = e.position;
    if (_touches.length == 2) {
      final p = _touches.values.toList();
      _pinchStartDist = (p[0] - p[1]).distance;
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_touches.containsKey(e.pointer)) return;
    _touches[e.pointer] = e.position;
    final start = _pinchStartDist;
    if (_touches.length != 2 || start == null || start <= 0) return;
    final p = _touches.values.toList();
    final ratio = (p[0] - p[1]).distance / start;
    if (ratio > 1.18 && _fit != BoxFit.cover) {
      setState(() => _fit = BoxFit.cover);
      _flash('Fill screen', icon: Icons.fit_screen_rounded);
      _pinchStartDist = null;
    } else if (ratio < 0.85 && _fit != BoxFit.contain) {
      setState(() => _fit = BoxFit.contain);
      _flash('Fit to screen', icon: Icons.aspect_ratio_rounded);
      _pinchStartDist = null;
    }
  }

  void _onPointerUp(PointerEvent e) {
    _touches.remove(e.pointer);
    if (_touches.length < 2) _pinchStartDist = null;
  }

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || !DesktopSupport.isWindows) return;
    // The controls change the volume on scroll; show it.
    Future<void>.delayed(const Duration(milliseconds: 60), () {
      if (!mounted) return;
      final v = _player.state.volume.round();
      _flash('Volume $v%', icon: v == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded);
    });
  }

  Future<void> _contextMenu(Offset at) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        PopupMenuItem(value: 'play', child: Text(_player.state.playing ? 'Pause' : 'Play')),
        PopupMenuItem(value: 'fs', child: Text(_fs ? 'Exit full screen   (F / Esc)' : 'Full screen   (F)')),
        const PopupMenuDivider(),
        for (final rate in _rates)
          CheckedPopupMenuItem(value: 'rate:$rate', checked: _rate == rate, child: Text('Speed ${_rateLabel(rate)}')),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(value: 'fit', checked: _fit == BoxFit.cover, child: const Text('Fill window (crop)')),
        CheckedPopupMenuItem(value: 'loop', checked: _loop, child: const Text('Loop')),
        PopupMenuItem(value: 'mute', child: Text(_muted ? 'Unmute   (M)' : 'Mute   (M)')),
        const PopupMenuItem(value: 'frame', child: Text('Save this frame')),
        if (_hasNext) const PopupMenuItem(value: 'next', child: Text('Next video   (N)')),
        const PopupMenuItem(value: 'keys', child: Text('Keyboard shortcuts   (?)')),
      ],
    );
    _keyFocus.requestFocus();
    if (choice == null || !mounted) return;
    if (choice == 'play') {
      unawaited(_player.playOrPause());
    } else if (choice == 'fs') {
      await _toggleFs();
    } else if (choice.startsWith('rate:')) {
      final rate = double.parse(choice.substring(5));
      await _setRate(rate);
      _flash('Speed ${_rateLabel(rate)}', icon: Icons.speed_rounded);
    } else if (choice == 'fit') {
      _cycleFit();
    } else if (choice == 'loop') {
      await _toggleLoop();
      _flash(_loop ? 'Loop on' : 'Loop off', icon: Icons.repeat_rounded);
    } else if (choice == 'mute') {
      await _toggleMute();
    } else if (choice == 'frame') {
      await _saveFrame();
    } else if (choice == 'next') {
      await _playNext();
    } else if (choice == 'keys') {
      await _showShortcuts();
    }
  }

  Future<void> _seekKey(int seconds) async {
    await _skip(seconds);
    _flash('${seconds > 0 ? '+' : '−'}${seconds.abs()} s',
        icon: seconds > 0 ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded);
  }

  Future<void> _volumeKey(double delta) async {
    final next = (_player.state.volume + delta).clamp(0.0, 100.0);
    await _player.setVolume(next);
    _volume = next;
    _flash('Volume ${next.round()}%', icon: next <= 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded);
  }

  Future<void> _rateKey(double delta) async {
    final next = ((_rate + delta) * 4).round() / 4;
    final clamped = next.clamp(0.25, 3.0);
    await _setRate(clamped);
    _flash('Speed ${_rateLabel(clamped)}', icon: Icons.speed_rounded);
  }

  Future<void> _jumpPercent(int tenth) async {
    final d = _player.state.duration;
    if (d <= Duration.zero) return;
    await _player.seek(d * (tenth / 10));
    _flash('${tenth * 10}%', icon: Icons.linear_scale_rounded);
  }

  Future<void> _frameStep(bool forward) async {
    try {
      await _player.pause();
      final native = _player.platform;
      if (native is NativePlayer) {
        await native.command([forward ? 'frame-step' : 'frame-back-step']);
      }
      _flash(forward ? 'Next frame' : 'Previous frame',
          icon: forward ? Icons.skip_next_rounded : Icons.skip_previous_rounded);
    } catch (_) {}
  }

  Future<void> _playPrevious() async {
    if (_queueIndex <= 0 || _queue.isEmpty) {
      await _player.seek(Duration.zero);
      return;
    }
    setState(() => _queueIndex -= 2);
    await _playNext();
  }

  Future<void> _toggleFullscreenKey() => _toggleFs();

  Future<void> _showShortcuts() async {
    const rows = [
      ['Space / K / click', 'Play or pause'],
      ['← / →', 'Back / forward 5 s'],
      ['J / L', 'Back / forward 10 s'],
      ['↑ / ↓  or mouse wheel', 'Volume'],
      ['M', 'Mute'],
      ['F / F11 / double-click', 'Full screen'],
      ['Right-click', 'Speed, fill, loop, mute, save frame'],
      ['Esc', 'Leave full screen / go back'],
      ['N / P', 'Next / previous video'],
      ['< / >', 'Slower / faster'],
      [', / .', 'Frame back / forward (paused)'],
      ['0 – 9', 'Jump to 0 – 90 %'],
      ['?', 'This list'],
    ];
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keyboard shortcuts'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 170,
                        child: Text(row[0], style: const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      Expanded(child: Text(row[1])),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
    _keyFocus.requestFocus();
  }

  /// Set by the `--key-log` test switch: prints every key the player handles.

  Map<ShortcutActivator, VoidCallback> _keyMap = const {};

  /// PC keys are handled here, globally, while the player is on screen, so
  /// they work whatever widget has focus (also in full screen and after
  /// clicks). Skipped while typing in a text field or when a dialog/menu is
  /// on top of the player.
  bool _onHardwareKey(KeyEvent event) {
    if (!mounted || event is KeyUpEvent) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    final focusCtx = FocusManager.instance.primaryFocus?.context;
    if (focusCtx != null &&
        (focusCtx.widget is EditableText || focusCtx.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return false;
    }
    if (widget.embedded) {
      // Docked beside the Library: only when the player area has focus.
      if (!_keyFocus.hasFocus) return false;
    }
    final keyboard = HardwareKeyboard.instance;
    for (final entry in _keyMap.entries) {
      if (entry.key.accepts(event, keyboard)) {
        if (InAppPlayerScreen.keyLog) {
          // ignore: avoid_print
          print('debug key ${event.logicalKey.keyLabel} fs=$_fs pos=${_player.state.position.inSeconds}s vol=${_player.state.volume.round()}');
        }
        entry.value();
        return true;
      }
    }
    return false;
  }

  Map<ShortcutActivator, VoidCallback> _desktopKeys() {
    void play() => unawaited(_player.playOrPause());
    return {
      const SingleActivator(LogicalKeyboardKey.space): play,
      const SingleActivator(LogicalKeyboardKey.keyK): play,
      const SingleActivator(LogicalKeyboardKey.mediaPlayPause): play,
      const SingleActivator(LogicalKeyboardKey.mediaPlay): () => unawaited(_player.play()),
      const SingleActivator(LogicalKeyboardKey.mediaPause): () => unawaited(_player.pause()),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () => unawaited(_seekKey(-5)),
      const SingleActivator(LogicalKeyboardKey.arrowRight): () => unawaited(_seekKey(5)),
      const SingleActivator(LogicalKeyboardKey.keyJ): () => unawaited(_seekKey(-10)),
      const SingleActivator(LogicalKeyboardKey.keyL): () => unawaited(_seekKey(10)),
      const SingleActivator(LogicalKeyboardKey.arrowUp): () => unawaited(_volumeKey(5)),
      const SingleActivator(LogicalKeyboardKey.arrowDown): () => unawaited(_volumeKey(-5)),
      const SingleActivator(LogicalKeyboardKey.keyM): () => unawaited(_toggleMute()),
      const SingleActivator(LogicalKeyboardKey.keyF): () => unawaited(_toggleFullscreenKey()),
      const SingleActivator(LogicalKeyboardKey.enter, alt: true): () => unawaited(_toggleFs()),
      const SingleActivator(LogicalKeyboardKey.f11): () => unawaited(_toggleFs()),
      const SingleActivator(LogicalKeyboardKey.escape): () {
        final state = _videoKey.currentState;
        if (_fs) {
          unawaited(_setFs(false));
        } else if (state != null && state.isFullscreen()) {
          unawaited(state.exitFullscreen());
        } else if (widget.embedded) {
          widget.onClose?.call();
        } else {
          unawaited(Navigator.maybePop(context));
        }
      },
      const SingleActivator(LogicalKeyboardKey.keyN): () => unawaited(_playNext()),
      const SingleActivator(LogicalKeyboardKey.mediaTrackNext): () => unawaited(_playNext()),
      const SingleActivator(LogicalKeyboardKey.keyP): () => unawaited(_playPrevious()),
      const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): () => unawaited(_playPrevious()),
      const CharacterActivator('<'): () => unawaited(_rateKey(-0.25)),
      const CharacterActivator('>'): () => unawaited(_rateKey(0.25)),
      const SingleActivator(LogicalKeyboardKey.comma): () => unawaited(_frameStep(false)),
      const SingleActivator(LogicalKeyboardKey.period): () => unawaited(_frameStep(true)),
      const CharacterActivator('?'): () => unawaited(_showShortcuts()),
      for (var i = 0; i <= 9; i++)
        SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + i)): () => unawaited(_jumpPercent(i)),
    };
  }

  Future<void> _playNext() async {
    if (!_hasNext) return;
    HapticFeedback.lightImpact();
    _cancelCountdown();
    await _saveResume();
    setState(() {
      _queueIndex += 1;
      _showEndCard = false;
      _completed = false;
      _ready = false;
      _error = null;
      _announcedResume = false;
      _resumeLanded = false;
      _resumeTargetMs = null;
      _resumeUntil = null;
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
                    const SizedBox(height: 4),
                    const Text(
                      'The screen dims when the timer ends.',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final minutes in [15, 20, 30, 45])
                          ChoiceChip(
                            label: Text('$minutes min'),
                            selected: _sleepMinutes == minutes && !_sleepAtEnd,
                            onSelected: (_) {
                              _setSleep(minutes);
                              setSheet(() {});
                            },
                          ),
                        ChoiceChip(
                          label: const Text('End of this video'),
                          selected: _sleepAtEnd,
                          onSelected: (_) {
                            _setSleepAtEnd();
                            setSheet(() {});
                          },
                        ),
                        if (_sleepMinutes != null || _sleepAtEnd)
                          ChoiceChip(
                            label: const Text('Off'),
                            selected: false,
                            onSelected: (_) {
                              _clearSleep();
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

  /// Windows: desktop controls (click = play/pause, double-click = full
  /// screen, wheel = volume, cursor hides) plus our keyboard map.
  Widget _desktopVideo() {
    final keys = _desktopKeys();
    final desktop = MaterialDesktopVideoControlsThemeData(
      playAndPauseOnTap: true,
      // Double-click is ours (real window full screen).
      toggleFullscreenOnDoublePress: widget.embedded,
      modifyVolumeOnScroll: true,
      hideMouseOnControlsRemoval: true,
      controlsHoverDuration: const Duration(seconds: 2),
      seekBarPositionColor: AppColors.secondaryContainer,
      seekBarThumbColor: AppColors.secondaryContainer,
      // Keys are handled once, by our CallbackShortcuts above, so they
      // work no matter which child has focus.
      keyboardShortcuts: const {},
      bottomButtonBar: [
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.skip_previous_rounded),
          onPressed: () => unawaited(_playPrevious()),
        ),
        const MaterialDesktopPlayOrPauseButton(),
        if (_hasNext)
          MaterialDesktopCustomButton(
            icon: const Icon(Icons.skip_next_rounded),
            onPressed: () => unawaited(_playNext()),
          ),
        const MaterialDesktopVolumeButton(),
        const MaterialDesktopPositionIndicator(),
        const Spacer(),
        MaterialDesktopCustomButton(
          icon: Text(_rateLabel(_rate), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
          onPressed: () => unawaited(_rateKey(_rate >= 2 ? -(_rate - 1) : 0.25)),
        ),
        widget.embedded
            ? const MaterialDesktopFullscreenButton()
            : MaterialDesktopCustomButton(
                icon: Icon(_fs ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded),
                onPressed: () => unawaited(_toggleFs()),
              ),
      ],
    );
    _keyMap = keys;
    return Builder(
      builder: (_) => Focus(
      focusNode: _keyFocus,
      autofocus: true,
      child: Stack(
        fit: StackFit.expand,
        children: [
          MaterialDesktopVideoControlsTheme(
            normal: desktop,
            fullscreen: desktop,
            child: Video(
              key: _videoKey,
              controller: _video,
              fill: Colors.black,
              fit: _fit,
              controls: _locked ? _hiddenControls : MaterialDesktopVideoControls,
            ),
          ),
        ],
      ),
      ),
    );
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
        MaterialCustomButton(
          icon: const Icon(Icons.screen_rotation_rounded),
          onPressed: () => unawaited(_rotate()),
        ),
        MaterialCustomButton(
          icon: Icon(_fs ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded),
          onPressed: () => unawaited(_toggleFs()),
        ),
      ],
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelCountdown();
    _chromeTimer?.cancel();
    _osdTimer?.cancel();
    if (DesktopSupport.isWindows) {
      HardwareKeyboard.instance.removeHandler(_onHardwareKey);
      if (!widget.embedded) InAppPlayerScreen.openCount--;
    }
    _keyFocus.dispose();
    _sleepTimer?.cancel();
    if (_fs || _forceLandscape) {
      if (DesktopSupport.isWindows) {
        unawaited(_mkChannel.invokeMethod<void>('Utils.ExitNativeFullscreen').catchError((_) {}));
      } else {
        unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
        unawaited(SystemChrome.setPreferredOrientations(const []));
      }
    }
    PlaybackBridge.clear(this);
    unawaited(PhoneBody.setPlayback(
      active: false,
      playing: false,
      title: _session.title,
      headset: false,
      volumeSeek: false,
    ));
    if (_dimmed) unawaited(PhoneBody.setBrightness(-1));
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
    final Widget video = DesktopSupport.isWindows ? _desktopVideo() : MaterialVideoControlsTheme(
      normal: theme,
      fullscreen: theme.copyWith(
        bottomButtonBarMargin: const EdgeInsets.only(left: 8, right: 8, bottom: 24),
      ),
      child: Video(
        controller: _video,
        fill: Colors.black,
        fit: _fit,
        controls: _locked || _inPip ? _hiddenControls : MaterialVideoControls,
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

    final narrow = MediaQuery.sizeOf(context).width < 560;
    return PopScope(
      // Back leaves full screen first.
      canPop: !_fs,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _fs) unawaited(_setFs(false));
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Listener(
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerUp,
        onPointerSignal: _onPointerSignal,
        child: SafeArea(
        top: !_fs,
        bottom: !_fs,
        left: !_fs,
        right: !_fs,
        child: Column(
          children: [
            if ((_chrome || _showEndCard) && !_fs)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () {
                      if (widget.embedded) {
                        widget.onClose?.call();
                      } else {
                        Navigator.maybePop(context);
                      }
                    },
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
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          _session.isPreview
                              ? 'Preview · not saved yet'
                              : _session.isVault
                                  ? 'Vault · PIN protected'
                                  : DesktopSupport.isWindows
                                      ? 'Space play · ←/→ seek · ↑/↓ volume · F full screen · ? shortcuts'
                                      : 'Double-tap sides to skip · pinch to fill',
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Lock screen',
                    onPressed: () => setState(() {
                      _locked = true;
                      _chrome = false;
                      _lockHint = true;
                    }),
                    icon: const Icon(Icons.lock_outline_rounded, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: 'Playback options',
                    onPressed: _showTools,
                    icon: const Icon(Icons.tune_rounded, color: Colors.white),
                  ),
                  if (narrow)
                    PopupMenuButton<String>(
                      tooltip: 'More',
                      icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
                      onSelected: (v) {
                        if (v == 'pip') unawaited(_playOverApps());
                        if (v == 'send') unawaited(showSendToPhone(context, File(_session.filePath!), _session.title));
                        if (v == 'tv') unawaited(_playOnTv());
                        if (v == 'open') unawaited(_openExternal());
                      },
                      itemBuilder: (_) => [
                        if (!_session.isVault && !DesktopSupport.isWindows)
                          const PopupMenuItem(value: 'pip', child: Text('Play over other apps')),
                        if (_session.filePath != null && !_session.isVault) ...const [
                          PopupMenuItem(value: 'send', child: Text('Send to another device')),
                          PopupMenuItem(value: 'tv', child: Text('Play on TV')),
                          PopupMenuItem(value: 'open', child: Text('Open in another app')),
                        ],
                      ],
                    ),
                  if (!narrow && !_session.isVault && !DesktopSupport.isWindows)
                    IconButton(
                      tooltip: 'Play over other apps',
                      onPressed: _playOverApps,
                      icon: const Icon(Icons.picture_in_picture_alt_rounded, color: Colors.white),
                    ),
                  if (!narrow && _session.filePath != null && !_session.isVault)
                    IconButton(
                      tooltip: 'Send to another device',
                      onPressed: () => unawaited(
                        showSendToPhone(context, File(_session.filePath!), _session.title),
                      ),
                      icon: const Icon(Icons.send_to_mobile_rounded, color: Colors.white),
                    ),
                  if (!narrow && _session.filePath != null && !_session.isVault)
                    IconButton(
                      tooltip: 'Play on TV',
                      onPressed: () => unawaited(_playOnTv()),
                      icon: const Icon(Icons.tv_rounded, color: Colors.white),
                    ),
                  if (!narrow && _session.filePath != null && !_session.isVault)
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
                    HeroMode(
                      enabled: _heroTag != null,
                      child: Hero(
                        tag: _heroTag ?? 'player-idle',
                        child: _FittedVideo(
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
                      ),
                    ),
                  if (_locked)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _lockHint = !_lockHint),
                        child: _lockHint
                            ? Center(
                                child: IconButton(
                                  tooltip: 'Unlock',
                                  iconSize: 42,
                                  onPressed: () => setState(() {
                                    _locked = false;
                                    _lockHint = false;
                                    _chrome = true;
                                  }),
                                  icon: const Icon(Icons.lock_open_rounded, color: Colors.white),
                                ),
                              )
                            : const SizedBox.expand(),
                      ),
                    ),
                  _osdLayer(),
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
