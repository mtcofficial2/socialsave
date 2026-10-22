import 'dart:async';
import 'package:social_save/features/library/session_ui.dart';
import 'package:social_save/features/library/share_session.dart';
import 'package:social_save/core/platform/plat.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:social_save/features/library/phone_handoff.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:open_filex/open_filex.dart';
import 'package:social_save/core/platform/desktop_support.dart';
import 'package:social_save/core/platform/player_identity.dart';
import 'package:social_save/core/platform/win_focus_stub.dart'
    if (dart.library.ffi) 'package:social_save/core/platform/win_focus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/platform/phone_body.dart';
import 'package:social_save/core/theme/app_colors.dart';
import 'package:social_save/features/library/device_media.dart';
import 'package:social_save/features/library/tiktok_ready.dart';
import 'package:social_save/features/player/pip.dart';
import 'package:social_save/features/player/desktop_pip.dart';
import 'package:window_manager/window_manager.dart';
import 'package:social_save/features/player/presentation/widgets/desktop_pip_controls.dart';
import 'package:social_save/features/player/presentation/widgets/phone_player_chrome.dart';
import 'package:social_save/features/player/presentation/widgets/subtitle_tools.dart';
import 'package:social_save/features/player/presentation/widgets/premium_player_chrome.dart';
import 'package:social_save/features/player/presentation/widgets/player_overlays.dart';
import 'package:social_save/features/player/video_stage_layout.dart';
import 'package:social_save/features/player/playback_bridge.dart';
import 'package:social_save/features/player/preview_timing.dart';
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

  /// Test copies (--test-data) never write resume positions.
  static bool noPersist = false;

  /// `--seek-bench`: time seeks, print the results, quit (tests only).
  static bool seekBench = false;

  /// `--fs-ui-test`: drive full screen with synthetic mouse and keys, log
  /// and capture the controls, quit (tests only).
  static bool fsUiTest = false;
  const InAppPlayerScreen({
    super.key,
    required this.session,
    this.embedded = false,
    this.onClose,
    this.startAt,
    this.fullscreenOnly = false,
    this.autoPlay = true,
  });

  final PlayerSession session;
  final bool embedded;
  final VoidCallback? onClose;

  /// Start here instead of the saved resume spot (no "Resumed at" note).
  final Duration? startAt;

  /// PC: the docked player's full screen. Opens in full screen and leaving
  /// full screen closes this page, handing the position back.
  final bool fullscreenOnly;
  final bool autoPlay;

  @override
  ConsumerState<InAppPlayerScreen> createState() => _InAppPlayerScreenState();
}

class _InAppPlayerScreenState extends ConsumerState<InAppPlayerScreen>
    with WidgetsBindingObserver, WindowListener {
  static const _rates = <double>[0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3];

  late final Player _player;
  late final VideoController _video;
  final _subs = <StreamSubscription<dynamic>>[];

  String? _error;
  bool _ready = false;
  bool _hintOpen = false;
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
  // PC seeking: key / button presses that land close together add up to one
  // seek instead of restarting the decoder on every press.
  Duration? _pendingSeek;
  Duration? _trailSeek;
  Timer? _seekTimer;
  bool _gpuDecode = false;
  // Docked player while its full-screen page is open.
  bool _handoff = false;

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
          isPreview: widget.session.isPreview,
          audioUrl: widget.session.audioUrl,
        ),
      ];
      _queueIndex = 0;
    }
    _player = Player(
      configuration: PlayerConfiguration(
        // PC: a bigger demuxer buffer keeps recent and upcoming video in RAM,
        // so short rewinds and skips don't go back to the disk.
        bufferSize: DesktopSupport.isWindows
            ? 150 * 1024 * 1024
            : 64 * 1024 * 1024,
        title: thisPlayerName,
      ),
    );
    unawaited(SubtitlePrefs.load());
    if (!DesktopSupport.isWindows) {
      unawaited(PlayerFirstHint.shouldShow().then((v) {
        if (mounted && v) setState(() => _hintOpen = true);
      }));
    }
    unawaited(_restoreFit());
    unawaited(PlayerChromePrefs.load().then((_) {
      if (mounted) setState(() {});
    }));
    _video = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        // Phones: YouTube files are often AV1 or VP9 and hardware decode
        // fails on many phones. PC: draw on the GPU (CPU drawing copied every
        // frame). Decode on the CPU up to 1080p: in tests it landed seeks in
        // about half the time of the GPU decoder, which also stalled at times;
        // bigger videos switch to the GPU decoder once their size is known.
        enableHardwareAcceleration: DesktopSupport.isWindows,
        hwdec: DesktopSupport.isWindows ? 'no' : null,
      ),
    );
    _subs.add(
      _player.stream.error.listen((message) {
        if (!mounted || message.trim().isEmpty) return;
        setState(() => _error = 'Playback error. Try Open in another app.');
      }),
    );
    _subs.add(
      _player.stream.completed.listen((done) {
        if (!mounted) return;
        setState(() => _completed = done);
        if (done) {
          unawaited(_clearResume());
          unawaited(_onFinished());
        }
      }),
    );
    _subs.add(
      _player.stream.rate.listen((value) {
        if (mounted) setState(() => _rate = value);
      }),
    );
    _subs.add(
      _player.stream.volume.listen((value) {
        if (!mounted) return;
        setState(() {
          _volume = value;
          _muted = value <= 0;
        });
      }),
    );
    _subs.add(
      _player.stream.width.listen((value) {
        if (!mounted || value == null || value <= 0) return;
        if (DesktopSupport.isWindows && value > 1920 && !_gpuDecode) {
          _gpuDecode = true;
          try {
            final dynamic native = _player.platform;
            unawaited(native.setProperty('hwdec', 'auto-safe') as Future<void>);
          } catch (_) {}
        }
        setState(() => _frameWidth = value);
        _syncPipAspect();
        _nudgeResume();
      }),
    );
    _subs.add(
      _player.stream.height.listen((value) {
        if (!mounted || value == null || value <= 0) return;
        setState(() => _frameHeight = value);
        _syncPipAspect();
      }),
    );
    _subs.add(
      _player.stream.position.listen((pos) {
        final a = _markA;
        final b = _markB;
        if (a != null && b != null && _loopAB && pos >= b) {
          unawaited(_player.seek(a));
          return;
        }
        if (InAppPlayerScreen.keyLog) {
          final prev = _logPos;
          _logPos = pos;
          if (prev != null && (pos - prev).abs() > const Duration(seconds: 2)) {
            // ignore: avoid_print
            print(
              'debug jump ${prev.inSeconds}s -> ${pos.inSeconds}s resume=$_resumeTargetMs',
            );
          }
        }
        _guardResume(pos);
        _saveResumeThrottled();
      }),
    );
    PipController.listen((inPip) {
      if (mounted) setState(() => _inPip = inPip);
    });
    _bindPhone();
    if (DesktopSupport.isWindows) {
      _keyMap = _desktopKeys();
      HardwareKeyboard.instance.addHandler(_onHardwareKey);
      InAppPlayerScreen.openCount++;
      windowManager.addListener(this);
    }
    _open();
    _showChrome();
    if (widget.fullscreenOnly && DesktopSupport.isWindows) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_setFs(true));
      });
    }
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
    _subs.add(
      PhoneBody.snapshots.stream.listen((snap) async {
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
      }),
    );
    _subs.add(
      PhoneBody.actions.stream.listen((action) async {
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
          _flash(
            '${action.delta > 0 ? '+' : '−'}${action.delta.abs()} s',
            icon: action.delta > 0
                ? Icons.fast_forward_rounded
                : Icons.fast_rewind_rounded,
          );
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
      }),
    );
    _subs.add(
      _player.stream.playing.listen((playing) {
        _pushSession();
      }),
    );
    _subs.add(_player.stream.duration.listen((_) => _pushSession()));
  }

  /// Media session state for the lock screen and the background service.
  void _pushSession() {
    if (!mounted) return;
    final settings = ref.read(settingsControllerProvider);
    unawaited(
      PhoneBody.setPlayback(
        active: true,
        playing: _player.state.playing,
        title: _session.title,
        headset: settings.headsetControls,
        volumeSeek: settings.volumeKeysSeek,
        background:
            Plat.isAndroid && settings.backgroundPlay && !_session.isVault,
        positionMs: _player.state.position.inMilliseconds,
        durationMs: _player.state.duration.inMilliseconds,
      ),
    );
  }

  // PC: pointer is over the top bar or the controls band; keep them up.
  bool _overControls = false;

  /// Phone: controls toggle only on a plain single tap.
  void _toggleChromeTap() {
    if (_locked || !mounted) return;
    if (_chrome) {
      _chromeTimer?.cancel();
      setState(() => _chrome = false);
    } else {
      _showChrome();
    }
  }

  /// Phone: any gesture (swipe, pinch, hold, double-tap) hides the controls and
  /// never reveals them; the HUD pills stay.
  void _hideChromeForGesture() {
    _chromeTimer?.cancel();
    if (mounted && _chrome) setState(() => _chrome = false);
  }

  void _showChrome() {
    _chromeTimer?.cancel();
    if (mounted && !_chrome) {
      setState(() => _chrome = true);
    } else {
      _chrome = true;
    }
    // PC full screen: 5 s after the last mouse move or key press.
    final idle = DesktopSupport.isWindows && _fs
        ? const Duration(seconds: 5)
        : const Duration(milliseconds: 3500);
    _chromeTimer = Timer(idle, () {
      if (!mounted || _showEndCard) return;
      if (_overControls) {
        _showChrome();
        return;
      }
      setState(() => _chrome = false);
      if (InAppPlayerScreen.keyLog) debugPrint('debug chrome hidden fs=$_fs');
    });
  }

  int _shotCount = 0;

  Future<void> _runFsUiTest() async {
    Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));
    await wait(3000);
    if (!mounted) return;
    Future<void> shot(String label) async {
      debugPrint(
        'debug ui $label: chrome=$_chrome fs=$_fs over=$_overControls '
        'cursorHidden=${_fs && !_chrome && !_overControls} pos=${_player.state.position.inSeconds}s',
      );
      await _debugShot();
    }

    if (widget.embedded) {
      await shot('docked before full screen');
      await _setFs(true);
      await wait(1500);
      await shot('docked after full screen closed (handoff=$_handoff playing=${_player.state.playing})');
      exit(0);
    }
    void hover(Offset at) => GestureBinding.instance.handlePointerEvent(
      PointerHoverEvent(position: at, kind: PointerDeviceKind.mouse),
    );
    void key(LogicalKeyboardKey logical, PhysicalKeyboardKey physical) {
      _onHardwareKey(
        KeyDownEvent(
          physicalKey: physical,
          logicalKey: logical,
          timeStamp: Duration.zero,
        ),
      );
    }

    if (!_fs) {
      await shot('windowed');
      key(LogicalKeyboardKey.keyF, PhysicalKeyboardKey.keyF);
      await wait(2500);
    }
    if (!mounted) return;
    final size = MediaQuery.sizeOf(context);
    final c = size.center(Offset.zero);
    hover(c);
    await wait(150);
    hover(c + const Offset(15, 0));
    await wait(800);
    await shot('full screen, mouse moved');
    await wait(3000);
    await shot('4 s after the move');
    await wait(2500);
    await shot('6.5 s after the move');
    hover(c + const Offset(-30, 0));
    await wait(500);
    await shot('mouse moved again');
    await wait(5600);
    await shot('5.6 s idle');
    final before = _player.state.position.inSeconds;
    key(LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight);
    await wait(700);
    await shot('Right arrow (from ${before}s)');
    await wait(5600);
    hover(Offset(c.dx, 24));
    await wait(7000);
    await shot('resting on the top bar 7 s');
    hover(Offset(c.dx, size.height - 30));
    await wait(7000);
    await shot('resting on the bottom controls 7 s');
    hover(c);
    await wait(5600);
    await shot('back on the picture 5.6 s');
    key(LogicalKeyboardKey.escape, PhysicalKeyboardKey.escape);
    await wait(1500);
    if (widget.fullscreenOnly) return;
    await shot('after Esc');
    exit(0);
  }

  /// `--key-log` tests: F12 saves the app's own frame (controls included,
  /// video picture not) to the temp folder and logs the control state.
  Future<void> _debugShot() async {
    try {
      final view = RendererBinding.instance.renderViews.first;
      // ignore: invalid_use_of_protected_member
      final layer = view.layer! as OffsetLayer;
      final size = view.size;
      // The root layer is in physical pixels.
      final physical = view.flutterView.physicalSize;
      final image = await layer.toImage(Offset.zero & physical);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final n = ++_shotCount;
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}ss_shot_$n.png',
      );
      await file.writeAsBytes(data!.buffer.asUint8List());
      debugPrint(
        'debug shot $n chrome=$_chrome fs=$_fs over=$_overControls size=${size.width.round()}x${size.height.round()} ${file.path}',
      );
    } catch (e) {
      debugPrint('debug shot failed $e');
    }
  }

  /// Keeps the controls up while the pointer rests on them.
  Widget _holdControls(Widget child, [String name = '']) {
    if (!DesktopSupport.isWindows) return child;
    return MouseRegion(
      onEnter: (_) {
        if (InAppPlayerScreen.keyLog || InAppPlayerScreen.fsUiTest) {
          debugPrint('debug enter $name');
        }
        _overControls = true;
        _showChrome();
      },
      onExit: (_) {
        if (InAppPlayerScreen.keyLog || InAppPlayerScreen.fsUiTest) {
          debugPrint('debug exit $name');
        }
        _overControls = false;
        _showChrome();
      },
      child: child,
    );
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
          const SnackBar(
            content: Text(
              'Save the video on this phone before playing it on a TV.',
            ),
          ),
        );
      }
      return;
    }
    final ok = await PhoneBody.playOnTv(path: path, title: _session.title);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No TV app on this phone could open the video.'),
        ),
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
        Plat.isAndroid &&
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

  Duration? _logPos;

  Future<void> _open() async {
    if (InAppPlayerScreen.keyLog) {
      // ignore: avoid_print
      print(
        'debug open ${_session.filePath ?? _session.networkUrl} embedded=${widget.embedded}',
      );
    }
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
      if (DesktopSupport.isWindows) await _tuneDesktopPlayer();
      final network = session.networkUrl != null && uri == session.networkUrl;
      if (network) await _tuneNetworkStart();
      if (session.isPreview) {
        PreviewTiming.mark('open');
        unawaited(_video.waitUntilFirstFrameRendered.then((_) {
          PreviewTiming.stop('first-frame');
        }).catchError((_) {}));
      }
      final startAt = widget.startAt;
      final start = startAt == null ? await _savedStart() : null;
      await _player.open(
        Media(uri, httpHeaders: headers, start: startAt),
        play: widget.autoPlay,
      );
      final audio = session.audioUrl;
      if (network && audio != null && audio.isNotEmpty) {
        // Preview of a split video+audio stream: add the audio as a track.
        await _player.setAudioTrack(AudioTrack.uri(audio));
      }
      if (Plat.isWeb) {
        // A browser can refuse autoplay (no recent tap); the play button
        // still works, so keep the player open instead of failing.
        try {
          await _player.play();
        } catch (_) {}
      } else if (widget.autoPlay) {
        await _player.play();
      }
      if (start != null) _armResume(start);
      await _restoreRate();
      // Web: wakelock_plus's no_sleep.js throws in browsers; a playing
      // <video> already keeps the screen on.
      if (!Plat.isWeb) await WakelockPlus.enable();
      if (session.isVault) {
        await DeviceMediaService().setSecure(true);
        await PipController.setAllowed(false);
      } else {
        await PipController.setAllowed(true);
      }
      if (mounted) setState(() => _ready = true);
      if (InAppPlayerScreen.seekBench && !widget.embedded) {
        unawaited(_runSeekBench());
      }
      if (InAppPlayerScreen.fsUiTest) unawaited(_runFsUiTest());
    } catch (error) {
      if (Plat.isWeb) debugPrint('SocialSave web player: $error');
      if (mounted) {
        setState(() {
          _error = session.isPreview
              ? 'This preview stream is not playable. Download the file, then play it.'
              : 'Could not play this file in SocialSave.';
        });
      }
    }
  }

  /// 1.0.45: quick start for network streams (Preview). mpv starts as soon as
  /// it can decode, keeps a small cache going in the background and gives up
  /// on a dead host instead of hanging. Local files are not touched (and
  /// neither is hwdec).
  Future<void> _tuneNetworkStart() async {
    if (PreviewTiming.legacy) return;
    try {
      final dynamic native = _player.platform;
      const props = {
        'cache': 'yes',
        'cache-pause-initial': 'no',
        'cache-pause-wait': '1',
        'demuxer-readahead-secs': '20',
        'demuxer-max-bytes': '${48 * 1024 * 1024}',
        'demuxer-lavf-analyzeduration': '1',
        'network-timeout': '20',
      };
      for (final e in props.entries) {
        await native.setProperty(e.key, e.value);
      }
    } catch (_) {}
  }

  /// libmpv settings for smooth seeking on PC.
  Future<void> _tuneDesktopPlayer() async {
    try {
      // NativePlayer (libmpv) is not part of the web build; call it loosely.
      final dynamic native = _player.platform;
      const props = {
        'cache': 'yes',
        'demuxer-max-back-bytes': '${75 * 1024 * 1024}',
        'demuxer-readahead-secs': '30',
        // Exact seeks for clicks and keys; the seek bar uses keyframe seeks
        // while it is dragged.
        'hr-seek': 'default',
        // While catching up to an exact seek point, skip drawing the frames
        // in between instead of showing each one.
        'hr-seek-framedrop': 'yes',
      };
      for (final e in props.entries) {
        await native.setProperty(e.key, e.value);
      }
    } catch (_) {}
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
      final expired =
          _resumeUntil != null && DateTime.now().isAfter(_resumeUntil!);
      if (expired) _resumeTargetMs = null;
      return;
    }
    final expired =
        _resumeUntil != null && DateTime.now().isAfter(_resumeUntil!);
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
    if (InAppPlayerScreen.keyLog) {
      // ignore: avoid_print
      print('debug resume-seek ${target.inSeconds}s');
    }
    await _player.seek(target);
  }

  void _announceResume(Duration position) {
    if (_announcedResume || !mounted) return;
    _announcedResume = true;
    final label = formatResumeClock(position);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Resumed at $label'),
        duration: const Duration(seconds: 5),
        persist: false,
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
    if (InAppPlayerScreen.noPersist) return;
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
    if (InAppPlayerScreen.noPersist) return;
    final key = _resumeKey;
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }

  // ---- `--seek-bench` (test only): time from a seek until playback moves.
  Future<void> _benchSkip(int s) => _skip(s);
  void _benchKey(int s) => unawaited(_seekKey(s));
  // Mirrors _DockSeek: keyframe seeks at most every 90 ms, exact on release.
  DateTime? _benchLast;
  void _benchDragTick(Duration t) {
    final now = DateTime.now();
    if (_benchLast != null &&
        now.difference(_benchLast!) < const Duration(milliseconds: 90)) {
      return;
    }
    _benchLast = now;
    final dynamic native = _player.platform;
    unawaited(
      native.command([
        'seek',
        (t.inMilliseconds / 1000).toStringAsFixed(3),
        'absolute+keyframes',
      ]) as Future<void>,
    );
  }

  void _benchDragEnd(Duration t) {
    _benchLast = null;
    unawaited(_player.seek(t));
  }

  Future<void> _runSeekBench() async {
    await Future<void>.delayed(const Duration(seconds: 4));
    final d = _player.state.duration;
    try {
      final dynamic native = _player.platform;
      debugPrint('debug bench hwdec=${await native.getProperty('hwdec-current')} codec=${await native.getProperty('video-codec')} '
          'size=${_frameWidth}x$_frameHeight dur=${d.inSeconds}s hr=${await native.getProperty('hr-seek')} '
          'cache=${await native.getProperty('cache')} dmb=${await native.getProperty('demuxer-max-bytes')} dmbb=${await native.getProperty('demuxer-max-back-bytes')}');
    } catch (e) {
      debugPrint('debug bench props $e');
    }
    var total = 0;
    Future<void> measure(String label, Duration Function() target, Future<void> Function() act) async {
      final sw = Stopwatch()..start();
      await act();
      final acted = sw.elapsedMilliseconds;
      final t = target();
      Duration? first;
      final done = Completer<void>();
      final sub = _player.stream.position.listen((pos) {
        if ((pos - t).abs() > const Duration(seconds: 6)) return;
        first ??= pos;
        if (pos - first! >= const Duration(milliseconds: 150) && !done.isCompleted) done.complete();
      });
      try {
        await done.future.timeout(const Duration(seconds: 15));
      } catch (_) {}
      await sub.cancel();
      final ms = sw.elapsedMilliseconds - acted;
      total += ms;
      debugPrint('debug bench $label ${ms}ms (input ${acted}ms) at ${_player.state.position.inMilliseconds / 1000}s');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
    final variants = (Platform.environment['SS_BENCH_HWDEC'] ?? '').split(',')
      ..removeWhere((v) => v.isEmpty);
    for (var round = 0; round < (variants.isEmpty ? 2 : variants.length); round++) {
      if (variants.isNotEmpty) {
        final dynamic native = _player.platform;
        await native.setProperty('hwdec', variants[round]);
        await Future<void>.delayed(const Duration(seconds: 2));
        debugPrint('debug bench variant hwdec=${variants[round]} now=${await native.getProperty('hwdec-current')}');
      }
      await measure('jump50', () => d * 0.5, () async => _player.seek(d * 0.5));
      var base = _player.state.position;
      await measure('back10', () => base - const Duration(seconds: 10), () => _benchSkip(-10));
      base = _player.state.position;
      await measure('fwd10', () => base + const Duration(seconds: 10), () => _benchSkip(10));
      base = _player.state.position;
      await measure('keys+5x3', () => base + const Duration(seconds: 15), () async {
        for (var i = 0; i < 3; i++) {
          _benchKey(5);
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
      });
      await measure('drag50to20', () => d * 0.2, () async {
        for (var i = 0; i <= 15; i++) {
          _benchDragTick(d * (0.5 - 0.02 * i));
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        _benchDragEnd(d * 0.2);
      });
      await measure('jump80', () => d * 0.8, () async => _player.seek(d * 0.8));
      await measure('jump15', () => d * 0.15, () async => _player.seek(d * 0.15));
    }
    debugPrint('debug bench TOTAL ${total}ms');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    exit(0);
  }

  Duration _clampSeek(Duration target) {
    final duration = _player.state.duration;
    if (target < Duration.zero) return Duration.zero;
    if (duration > Duration.zero && target > duration) return duration;
    return target;
  }

  Future<void> _skip(int seconds) async {
    if (DesktopSupport.isWindows) {
      // Count from a seek that is still on its way, so three quick presses
      // of +5 s land 15 s ahead.
      _queueSeek((_pendingSeek ?? _player.state.position) + Duration(seconds: seconds));
      return;
    }
    final next = _player.state.position + Duration(seconds: seconds);
    await _player.seek(_clampSeek(next));
  }

  /// First press seeks at once; presses during the next 150 ms are added up
  /// and sent as one seek when they stop.
  void _queueSeek(Duration target) {
    final t = _clampSeek(target);
    _pendingSeek = t;
    if (_seekTimer == null) {
      unawaited(_player.seek(t));
    } else {
      _trailSeek = t;
      _seekTimer!.cancel();
    }
    _seekTimer = Timer(const Duration(milliseconds: 150), () {
      _seekTimer = null;
      final trail = _trailSeek;
      _trailSeek = null;
      if (trail != null) {
        unawaited(_player.seek(trail).whenComplete(() => _pendingSeek = null));
      } else {
        _pendingSeek = null;
      }
    });
  }

  static const _speedPrefKey = 'player.rate.v1';

  Future<void> _setRate(double rate) async {
    await _player.setRate(rate);
    if (mounted) setState(() => _rate = rate);
    // Remember the speed for the next video (1.0.37). The 2x long-press
    // boost goes through the controls, not here, so it is never saved.
    try {
      final prefs = await SharedPreferences.getInstance();
      if (rate == 1) {
        await prefs.remove(_speedPrefKey);
      } else {
        await prefs.setDouble(_speedPrefKey, rate);
      }
    } catch (_) {}
  }

  Future<void> _restoreRate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble(_speedPrefKey);
      if (saved == null || saved == _player.state.rate) return;
      final rate = saved.clamp(0.25, 4.0).toDouble();
      await _player.setRate(rate);
      if (mounted) setState(() => _rate = rate);
    } catch (_) {}
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

  static const _fitPrefKey = 'player.fill.v1';

  void _cycleFit() {
    setState(() {
      _fit = _fit == BoxFit.contain ? BoxFit.cover : BoxFit.contain;
    });
    unawaited(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_fitPrefKey, _fit == BoxFit.cover);
      } catch (_) {}
    }());
  }

  Future<void> _restoreFit() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getBool(_fitPrefKey) ?? false) && mounted) {
        setState(() => _fit = BoxFit.cover);
      }
    } catch (_) {}
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
      text:
          '${pos.inMinutes}:${(pos.inSeconds % 60).toString().padLeft(2, '0')}',
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
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
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
    final file = File(
      '${dir.path}/frame_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    await file.writeAsBytes(bytes);
    await Share.shareXFiles([XFile(file.path)], text: _session.title);
  }

  Future<void> _openExternal() async {
    final path = _session.filePath;
    if (path == null || !File(path).existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Download the video first to open it in another app.',
            ),
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

  /// Windows: the window itself becomes the mini player (same player, so
  /// playback never restarts).
  Future<void> _toggleDesktopPip() async {
    if (!DesktopSupport.isWindows) return;
    if (_inPip) {
      setState(() => _inPip = false);
      await DesktopPip.exit();
      return;
    }
    if (_fs) await _setFs(false);
    final w = _frameWidth;
    final h = _frameHeight;
    final aspect = (w != null && h != null && h > 0) ? w / h : 16 / 9;
    // Notices (USB connected, etc.) would cover the mini player.
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    await DesktopPip.enter(aspect: aspect);
    if (mounted) setState(() => _inPip = true);
  }

  bool _closingPip = false;

  /// Back is held for a check only where auto picture in picture can apply.
  bool get _mayAutoPip =>
      DesktopSupport.isWindows &&
      !widget.embedded &&
      !_inPip &&
      !_closingPip &&
      !_session.isVault &&
      ref.read(settingsControllerProvider).autoPip;

  /// PC auto picture in picture: on, a video is playing, not the vault,
  /// not already in the mini player, and not docked beside the Library.
  bool _autoPipReady({bool blur = false}) {
    if (!DesktopSupport.isWindows || _inPip || _closingPip || widget.embedded) return false;
    if (_session.isVault || !_ready || !_player.state.playing) return false;
    final s = ref.read(settingsControllerProvider);
    return blur ? (s.autoPip && s.autoPipOnBlur) : s.autoPip;
  }

  @override
  void onWindowMinimize() {
    if (!_autoPipReady()) return;
    unawaited(() async {
      await windowManager.restore();
      await _toggleDesktopPip();
    }());
  }

  @override
  void onWindowBlur() {
    if (!_autoPipReady(blur: true)) return;
    unawaited(_toggleDesktopPip());
  }

  Future<void> _playOverApps() async {
    if (DesktopSupport.isWindows) {
      await _toggleDesktopPip();
      return;
    }
    _syncPipAspect();
    final ok = await PipController.enter();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This device cannot play over other apps.'),
        ),
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
          child: PlayerHudPill(text: _osd ?? '', icon: _osdIcon),
        ),
      ),
    );
  }

  Future<void> _openDockedFullscreen() async {
    if (_handoff || !mounted) return;
    final wasPlaying = _player.state.playing;
    final at = _pendingSeek ?? _player.state.position;
    setState(() => _handoff = true);
    await _player.pause();
    if (!mounted) return;
    final s = widget.session;
    final session = PlayerSession(
      title: s.title,
      platform: s.platform,
      filePath: s.filePath,
      networkUrl: s.networkUrl,
      thumbnailUrl: s.thumbnailUrl,
      author: s.author,
      referer: s.referer,
      httpHeaders: s.httpHeaders,
      isPreview: s.isPreview,
      isVault: s.isVault,
      queue: _queue,
      queueIndex: _queueIndex,
    );
    final back = await Navigator.of(context, rootNavigator: true)
        .push<_FsHandBack>(
          PageRouteBuilder<_FsHandBack>(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, _, _) => InAppPlayerScreen(
              session: session,
              startAt: at,
              fullscreenOnly: true,
              autoPlay: wasPlaying,
            ),
          ),
        );
    if (!mounted) return;
    setState(() => _handoff = false);
    if (back != null) {
      if (back.queueIndex != _queueIndex &&
          back.queueIndex >= 0 &&
          back.queueIndex < _queue.length) {
        setState(() => _queueIndex = back.queueIndex - 1);
        await _playNext();
      }
      if (back.rate != _rate) await _setRate(back.rate);
      await _player.setVolume(back.volume);
      await _player.seek(back.position);
      if (back.playing) await _player.play();
    }
    _refocus();
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
      // Docked beside the Library: open the full player in full screen (same
      // controls and buttons), then carry on here where it stopped.
      if (on) await _openDockedFullscreen();
      return;
    }
    if (!on && widget.fullscreenOnly && DesktopSupport.isWindows) {
      try {
        await _mkChannel.invokeMethod<void>('Utils.ExitNativeFullscreen');
      } catch (_) {}
      if (!mounted) return;
      setState(() => _fs = false);
      Navigator.of(context).pop(
        _FsHandBack(
          position: _pendingSeek ?? _player.state.position,
          playing: _player.state.playing,
          queueIndex: _queueIndex,
          rate: _rate,
          volume: _player.state.volume,
        ),
      );
      return;
    }
    setState(() => _fs = on);
    try {
      if (DesktopSupport.isWindows) {
        // Real window full screen (no title bar / taskbar); the plugin
        // restores the old size and position on exit.
        await _mkChannel.invokeMethod<void>(
          on ? 'Utils.EnterNativeFullscreen' : 'Utils.ExitNativeFullscreen',
        );
      } else {
        await _applyOrientation();
      }
    } catch (_) {}
    if (on) _showChrome();
    _refocus();
    _flash(
      on ? 'Full screen' : 'Full screen off',
      icon: on ? Icons.fullscreen_rounded : Icons.fullscreen_exit_rounded,
    );
  }

  /// Phone: landscape videos go landscape in full screen, portrait videos
  /// stay portrait; the rotate button flips it.
  Future<void> _applyOrientation() async {
    if (DesktopSupport.isWindows) return;
    if (_fs) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      final landscape = _forceLandscape || (_landscapeVideo && !_forcePortrait);
      await SystemChrome.setPreferredOrientations(
        landscape
            ? const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : const [DeviceOrientation.portraitUp],
      );
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(
        _forceLandscape
            ? const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : const [],
      );
    }
  }

  bool _forcePortrait = false;

  Future<void> _rotate() async {
    final landscapeNow =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    setState(() {
      _forceLandscape = !landscapeNow;
      _forcePortrait = landscapeNow;
    });
    if (!_fs && !_forceLandscape) {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await SystemChrome.setPreferredOrientations(const []);
      return;
    }
    await _applyOrientation();
  }

  // Pointer bookkeeping shared by phone (pinch) and PC (focus, double-click,
  // right-click menu, wheel feedback).
  void _onPointerDown(PointerDownEvent e) {
    // Touch: controls are revealed only by a plain tap (PlayerGestureLayer).
    if (DesktopSupport.isWindows) _showChrome();
    if (DesktopSupport.isWindows) {
      _keyFocus.requestFocus();
      if (e.kind == PointerDeviceKind.mouse &&
          e.buttons == kSecondaryMouseButton) {
        unawaited(_contextMenu(e.position));
        return;
      }
      if (e.buttons == kPrimaryMouseButton) {
        final now = DateTime.now();
        final last = _lastClick;
        final pos = _lastClickPos;
        // A double-click on a control (play, skip, seek) is two presses of
        // that control, not a full-screen toggle.
        if (_overControls) {
          _lastClick = null;
          return;
        }
        if (last != null &&
            pos != null &&
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
      _flash(
        'Volume $v%',
        icon: v == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
      );
    });
  }

  Future<void> _contextMenu(Offset at) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: 'play',
          child: Text(_player.state.playing ? 'Pause' : 'Play'),
        ),
        PopupMenuItem(
          value: 'fs',
          child: Text(
            _fs ? 'Exit full screen   (F / Esc)' : 'Full screen   (F)',
          ),
        ),
        const PopupMenuDivider(),
        for (final rate in _rates)
          CheckedPopupMenuItem(
            value: 'rate:$rate',
            checked: _rate == rate,
            child: Text('Speed ${_rateLabel(rate)}'),
          ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(
          value: 'fit',
          checked: _fit == BoxFit.cover,
          child: const Text('Fill window (crop)'),
        ),
        CheckedPopupMenuItem(
          value: 'loop',
          checked: _loop,
          child: const Text('Loop'),
        ),
        PopupMenuItem(
          value: 'mute',
          child: Text(_muted ? 'Unmute   (M)' : 'Mute   (M)'),
        ),
        const PopupMenuItem(value: 'frame', child: Text('Save this frame')),
        if (_hasNext)
          const PopupMenuItem(value: 'next', child: Text('Next video   (N)')),
        const PopupMenuItem(
          value: 'keys',
          child: Text('Keyboard shortcuts   (?)'),
        ),
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
    _flash(
      '${seconds > 0 ? '+' : '−'}${seconds.abs()} s',
      icon: seconds > 0
          ? Icons.fast_forward_rounded
          : Icons.fast_rewind_rounded,
    );
  }

  Future<void> _volumeKey(double delta) async {
    final next = (_player.state.volume + delta).clamp(0.0, 100.0);
    await _player.setVolume(next);
    _volume = next;
    _flash(
      'Volume ${next.round()}%',
      icon: next <= 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
    );
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
      if (!Plat.isWeb) {
        // NativePlayer (libmpv) is not part of the web build; call it loosely.
        final dynamic native = _player.platform;
        await native.command([forward ? 'frame-step' : 'frame-back-step']);
      }
      _flash(
        forward ? 'Next frame' : 'Previous frame',
        icon: forward ? Icons.skip_next_rounded : Icons.skip_previous_rounded,
      );
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
                        child: Text(
                          row[0],
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Expanded(child: Text(row[1])),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
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
    if (!mounted || event is KeyUpEvent || _handoff) return false;
    // Docked player in media_kit's own full-screen page: that page is a
    // separate route on top, so take every player key while it is open.
    final dockedFs =
        widget.embedded && (_videoKey.currentState?.isFullscreen() ?? false);
    final route = ModalRoute.of(context);
    if (!dockedFs && route != null && !route.isCurrent) return false;
    final focusCtx = FocusManager.instance.primaryFocus?.context;
    if (focusCtx != null &&
        (focusCtx.widget is EditableText ||
            focusCtx.findAncestorWidgetOfExactType<EditableText>() != null)) {
      return false;
    }
    if (widget.embedded && !dockedFs) {
      // Docked beside the Library: only when the player area has focus.
      if (!_keyFocus.hasFocus) return false;
    }
    if (InAppPlayerScreen.keyLog && event.logicalKey == LogicalKeyboardKey.f12) {
      unawaited(_debugShot());
      return true;
    }
    final keyboard = HardwareKeyboard.instance;
    for (final entry in _keyMap.entries) {
      if (entry.key.accepts(event, keyboard)) {
        if (InAppPlayerScreen.keyLog) {
          // ignore: avoid_print
          print(
            'debug key ${event.logicalKey.keyLabel} fs=$_fs pos=${_player.state.position.inSeconds}s vol=${_player.state.volume.round()}',
          );
        }
        entry.value();
        _showChrome();
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
      const SingleActivator(LogicalKeyboardKey.mediaPlay): () =>
          unawaited(_player.play()),
      const SingleActivator(LogicalKeyboardKey.mediaPause): () =>
          unawaited(_player.pause()),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
          unawaited(_seekKey(-5)),
      const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
          unawaited(_seekKey(5)),
      const SingleActivator(LogicalKeyboardKey.keyJ): () =>
          unawaited(_seekKey(-10)),
      const SingleActivator(LogicalKeyboardKey.keyL): () =>
          unawaited(_seekKey(10)),
      const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
          unawaited(_volumeKey(5)),
      const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
          unawaited(_volumeKey(-5)),
      const SingleActivator(LogicalKeyboardKey.keyM): () =>
          unawaited(_toggleMute()),
      const SingleActivator(LogicalKeyboardKey.keyF): () =>
          unawaited(_toggleFullscreenKey()),
      const SingleActivator(LogicalKeyboardKey.enter, alt: true): () =>
          unawaited(_toggleFs()),
      const SingleActivator(LogicalKeyboardKey.f11): () =>
          unawaited(_toggleFs()),
      const SingleActivator(LogicalKeyboardKey.keyI): () =>
          unawaited(_toggleDesktopPip()),
      const SingleActivator(LogicalKeyboardKey.escape): () {
        final state = _videoKey.currentState;
        if (_inPip) {
          unawaited(_toggleDesktopPip());
        } else if (_fs) {
          unawaited(_setFs(false));
        } else if (state != null && state.isFullscreen()) {
          unawaited(state.exitFullscreen());
        } else if (widget.embedded) {
          widget.onClose?.call();
        } else {
          unawaited(Navigator.maybePop(context));
        }
      },
      const SingleActivator(LogicalKeyboardKey.keyN): () =>
          unawaited(_playNext()),
      const SingleActivator(LogicalKeyboardKey.mediaTrackNext): () =>
          unawaited(_playNext()),
      const SingleActivator(LogicalKeyboardKey.keyP): () =>
          unawaited(_playPrevious()),
      const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): () =>
          unawaited(_playPrevious()),
      const CharacterActivator('<'): () => unawaited(_rateKey(-0.25)),
      const CharacterActivator('>'): () => unawaited(_rateKey(0.25)),
      const SingleActivator(LogicalKeyboardKey.comma): () =>
          unawaited(_frameStep(false)),
      const SingleActivator(LogicalKeyboardKey.period): () =>
          unawaited(_frameStep(true)),
      const CharacterActivator('?'): () => unawaited(_showShortcuts()),
      for (var i = 0; i <= 9; i++)
        SingleActivator(
          LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + i),
        ): () =>
            unawaited(_jumpPercent(i)),
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
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (context) {
        return PlayerGlassSheet(child: SafeArea(
          child: SingleChildScrollView(child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: StatefulBuilder(
              builder: (context, setSheet) {
                // 1.0.45: the sheet follows the theme (light and dark).
                final cs = Theme.of(context).colorScheme;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Playback',
                      style: TextStyle(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Double-tap sides to skip 10s. Hold to play at 2x. Drag right for volume, left for brightness.',
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    const PlayerSectionHeader('Sleep timer', Icons.bedtime_rounded),
                    const SizedBox(height: 4),
                    Text(
                      'The screen dims when the timer ends.',
                      style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
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
                          label: Text('End of this video'),
                          selected: _sleepAtEnd,
                          onSelected: (_) {
                            _setSleepAtEnd();
                            setSheet(() {});
                          },
                        ),
                        if (_sleepMinutes != null || _sleepAtEnd)
                          ChoiceChip(
                            label: Text('Off'),
                            selected: false,
                            onSelected: (_) {
                              _clearSleep();
                              setSheet(() {});
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const PlayerSectionHeader('Speed', Icons.speed_rounded),
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
                    const PlayerSectionHeader('Playback', Icons.play_circle_outline_rounded),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _loop,
                      title: Text(
                        'Loop this video',
                        style: TextStyle(color: cs.onSurface),
                      ),
                      onChanged: (_) async {
                        await _toggleLoop();
                        setSheet(() {});
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _pinchZoom,
                      title: Text(
                        'Pinch to zoom',
                        style: TextStyle(color: cs.onSurface),
                      ),
                      subtitle: Text(
                        'Turn off to keep skip, seek, and volume gestures.',
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                      ),
                      onChanged: (value) {
                        setState(() => _pinchZoom = value);
                        setSheet(() {});
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _fit == BoxFit.cover,
                      title: Text(
                        'Fill the screen',
                        style: TextStyle(color: cs.onSurface),
                      ),
                      subtitle: Text(
                        'Off keeps the real video shape. On fills the window.',
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                      ),
                      onChanged: (_) {
                        _cycleFit();
                        setSheet(() {});
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Icons.timelapse_rounded,
                        color: cs.onSurfaceVariant,
                      ),
                      title: Text(
                        'Jump to time',
                        style: TextStyle(color: cs.onSurface),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        unawaited(_jumpToTime());
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Icons.camera_alt_outlined,
                        color: cs.onSurfaceVariant,
                      ),
                      title: Text(
                        'Save a still frame',
                        style: TextStyle(color: cs.onSurface),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        unawaited(_saveFrame());
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Icons.repeat_on_rounded,
                        color: cs.onSurfaceVariant,
                      ),
                      title: Text(
                        _loopAB ? 'A–B loop on' : 'Set A–B loop',
                        style: TextStyle(color: cs.onSurface),
                      ),
                      subtitle: Text(
                        _loopAB
                            ? 'Playing between the two marks'
                            : 'Mark this moment as A, then again as B',
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                      onTap: () {
                        _toggleAB();
                        setSheet(() {});
                      },
                    ),
                    if (_player.state.tracks.audio.length > 1) ...[
                      Text(
                        'Audio',
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final track in _player.state.tracks.audio)
                            ChoiceChip(
                              label: Text(
                                track.title ?? track.language ?? track.id,
                              ),
                              selected:
                                  _player.state.track.audio.id == track.id,
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
                      Text(
                        'Captions',
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        children: [
                          ChoiceChip(
                            label: Text('Off'),
                            selected: _player.state.track.subtitle.id == 'no',
                            onSelected: (_) {
                              unawaited(
                                _player.setSubtitleTrack(SubtitleTrack.no()),
                              );
                              setSheet(() {});
                            },
                          ),
                          for (final track in _player.state.tracks.subtitle)
                            ChoiceChip(
                              label: Text(
                                track.title ?? track.language ?? track.id,
                              ),
                              selected:
                                  _player.state.track.subtitle.id == track.id,
                              onSelected: (_) {
                                unawaited(_player.setSubtitleTrack(track));
                                setSheet(() {});
                              },
                            ),
                        ],
                      ),
                    ],
                    const PlayerSectionHeader('Interface', Icons.tune_rounded),
                    ClassicControlsSwitch(
                      onChanged: () {
                        setSheet(() {});
                        if (mounted) setState(() {});
                      },
                    ),
                    SubtitleToolsRow(
                      player: _player,
                      onChanged: () {
                        setSheet(() {});
                        if (mounted) setState(() {});
                      },
                    ),
                    Row(
                      children: [
                        Icon(
                          _muted
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          color: cs.onSurface,
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
          ))));
      },
    );
  }

  String _rateLabel(double rate) {
    if (rate == rate.roundToDouble()) return '${rate.toStringAsFixed(0)}x';
    return '${rate}x';
  }

  void _cyclePhoneRate() {
    var index = 0;
    for (var i = 0; i < _rates.length; i++) {
      if ((_rates[i] - _rate).abs() < 0.01) {
        index = i;
        break;
      }
    }
    unawaited(_setRate(_rates[(index + 1) % _rates.length]));
  }

  String _phoneSubtitle() {
    if (_session.isPreview) return 'Preview · not saved yet';
    if (_session.isVault) return 'Vault · PIN protected';
    // 1.0.44: no hint line under the title; the player stays quiet.
    return '';
  }

  Widget _phoneMoreButton() {
    return PopupMenuButton<String>(
      tooltip: 'More',
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_vert_rounded, color: Colors.white, size: 22),
      onSelected: (value) {
        if (value == 'pip') unawaited(_playOverApps());
        if (value == 'session') sendToSessionPeer(context, File(_session.filePath!));
        if (value == 'send') {
          unawaited(
            showSendToPhone(context, File(_session.filePath!), _session.title),
          );
        }
        if (value == 'tv') unawaited(_playOnTv());
        if (value == 'open') unawaited(_openExternal());
        if (value == 'rotate') unawaited(_rotate());
      },
      itemBuilder: (_) => [
        if (_session.filePath != null && !_session.isVault && ShareSession.active)
          PopupMenuItem(value: 'session', child: Text('Send to ${ShareSession.peer.value!.name}')),
        if (_session.filePath != null && !_session.isVault) ...const [
          PopupMenuItem(value: 'send', child: Text('Send to another device')),
          PopupMenuItem(value: 'open', child: Text('Open in another app')),
        ],
        const PopupMenuItem(value: 'rotate', child: Text('Rotate')),
      ],
    );
  }

  Widget _phoneChrome() {
    final canShare = _session.filePath != null && !_session.isVault;
    if (!PlayerChromePrefs.classic.value) {
      return PremiumPlayerChrome(
        player: _player,
        title: _session.title,
        subtitle: _phoneSubtitle(),
        rate: _rate,
        rates: _rates,
        loop: _loop,
        muted: _muted,
        filling: _fit == BoxFit.cover,
        fullscreen: _fs,
        hasNext: _hasNext,
        hasPrevious: _queueIndex > 0,
        landscape: MediaQuery.orientationOf(context) == Orientation.landscape,
        showPip: !_session.isVault,
        onBack: () {
          if (widget.embedded) {
            widget.onClose?.call();
          } else if (_fs) {
            unawaited(_setFs(false));
          } else {
            Navigator.maybePop(context);
          }
        },
        onLock: () => setState(() {
          _locked = true;
          _chrome = false;
          _lockHint = true;
        }),
        onTools: () => unawaited(_showTools()),
        onPip: () => unawaited(_playOverApps()),
        onSkip: (seconds) => unawaited(_skip(seconds)),
        onPrevious: () => unawaited(_playPrevious()),
        onNext: () => unawaited(_playNext()),
        onSetRate: (r) => unawaited(_setRate(r)),
        onLoop: () => unawaited(_toggleLoop()),
        onMute: () => unawaited(_toggleMute()),
        onFit: _cycleFit,
        onFullscreen: () => unawaited(_toggleFs()),
        onRotate: () => unawaited(_rotate()),
        onAB: _toggleAB,
        abLabel: _markA == null ? null : (_markB == null ? 'A' : 'A-B'),
        onSleep: (m) {
          if (m == 0) {
            _clearSleep();
          } else if (m < 0) {
            _setSleepAtEnd();
          } else {
            _setSleep(m);
          }
        },
        sleepActive: _sleepMinutes != null || _sleepAtEnd,
        onSend: canShare
            ? () => showSendToPhone(context, File(_session.filePath!), _session.title)
            : null,
        moreMenu: _phoneMoreButton(),
      );
    }
    return PhonePlayerChrome(
      player: _player,
      title: _session.title,
      subtitle: _phoneSubtitle(),
      platform: _session.platform,
      frameWidth: _frameWidth,
      frameHeight: _frameHeight,
      rate: _rate,
      loop: _loop,
      muted: _muted,
      filling: _fit == BoxFit.cover,
      fullscreen: _fs,
      hasNext: _hasNext,
      vault: _session.isVault,
      landscape: MediaQuery.orientationOf(context) == Orientation.landscape,
      showPip: !_session.isVault,
      showCast: canShare,
      onBack: () {
        if (widget.embedded) {
          widget.onClose?.call();
        } else if (_fs) {
          unawaited(_setFs(false));
        } else {
          Navigator.maybePop(context);
        }
      },
      onLock: () => setState(() {
        _locked = true;
        _chrome = false;
        _lockHint = true;
      }),
      onTools: () => unawaited(_showTools()),
      onPip: () => unawaited(_playOverApps()),
      onCast: () => unawaited(_playOnTv()),
      onSkip: (seconds) => unawaited(_skip(seconds)),
      onPrevious: () => unawaited(_playPrevious()),
      onNext: () => unawaited(_playNext()),
      onRate: _cyclePhoneRate,
      onLoop: () => unawaited(_toggleLoop()),
      onMute: () => unawaited(_toggleMute()),
      onFit: _cycleFit,
      onFullscreen: () => unawaited(_toggleFs()),
      moreMenu: _phoneMoreButton(),
    );
  }

  Widget _videoHero(Widget video) {
    return HeroMode(
      enabled: _heroTag != null,
      child: Hero(
        tag: _heroTag ?? 'player-idle',
        child: _pinchZoom
            ? InteractiveViewer(
                minScale: 1,
                maxScale: 3,
                panEnabled: false,
                child: video,
              )
            : video,
      ),
    );
  }

  /// Phone: the picture fills the screen and the mock chrome sits on it.
  Widget _phoneStage(Widget video) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        PlayerGestureLayer(
          onBoost: (on) => unawaited(_player.setRate(on ? 2.0 : _rate)),
          onTap: _toggleChromeTap,
          onGesture: _hideChromeForGesture,
          child: _videoHero(video),
        ),
        IgnorePointer(
          ignoring: _locked || (!_chrome && !_showEndCard),
          child: AnimatedOpacity(
            opacity: !_locked && (_chrome || _showEndCard) ? 1 : 0,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            child: AnimatedSlide(
              offset: !_locked && (_chrome || _showEndCard)
                  ? Offset.zero
                  : const Offset(0, 0.025),
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              child: _phoneChrome(),
            ),
          ),
        ),
        if (_ready && _hintOpen && !_locked)
          PlayerFirstHint(
            onDismiss: () {
              setState(() => _hintOpen = false);
              unawaited(PlayerFirstHint.markSeen());
            },
          ),
      ],
    );
  }

  Widget _lockLayer(bool phone) {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _lockHint = !_lockHint),
        child: _lockHint
            ? Center(child: phone ? _phoneUnlock() : _desktopUnlock())
            : const SizedBox.expand(),
      ),
    );
  }

  Widget _desktopUnlock() {
    return IconButton(
      tooltip: 'Unlock',
      iconSize: 42,
      onPressed: () => setState(() {
        _locked = false;
        _lockHint = false;
        _chrome = true;
      }),
      icon: const Icon(Icons.lock_open_rounded, color: Colors.white),
    );
  }

  Widget _phoneUnlock() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: const Color(0xE62A2A2A),
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => setState(() {
              _locked = false;
              _lockHint = false;
              _chrome = true;
            }),
            child: const Padding(
              padding: EdgeInsets.fromLTRB(16, 10, 22, 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: PhonePlayerChrome.violet,
                      shape: BoxShape.circle,
                    ),
                    child: SizedBox(
                      width: 32,
                      height: 32,
                      child: Icon(
                        Icons.lock_open_rounded,
                        color: PhonePlayerChrome.onViolet,
                        size: 18,
                      ),
                    ),
                  ),
                  SizedBox(width: 12),
                  Text(
                    'Tap to Unlock',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 32),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0x99000000),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Text(
            'Controls are locked so a tap does not change playback.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFFC7C5D4), fontSize: 12),
          ),
        ),
      ],
    );
  }

  /// PC (1.0.44): the minimal controls float over the picture, like on the
  /// phone. Hover shows them, they fade after the idle time, Space / arrows /
  /// F / double-click keep working.
  bool get _deskMinimal => DesktopSupport.isWindows && !PlayerChromePrefs.classic.value;

  Widget _desktopMoreMenu() {
    final file = _session.filePath;
    final share = file != null && !_session.isVault;
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return PopupMenuButton<String>(
      tooltip: 'Share',
      padding: EdgeInsets.zero,
      // 1.0.45: the menu follows the theme; the button on the picture stays light.
      color: dark ? const Color(0xF2161619) : cs.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: dark ? Colors.white.withValues(alpha: 0.08) : cs.outlineVariant.withValues(alpha: 0.7)),
      ),
      icon: Icon(Icons.ios_share_rounded, color: Colors.white.withValues(alpha: 0.88), size: 20),
      onSelected: (v) {
        if (v == 'send') unawaited(showSendToPhone(context, File(file!), _session.title));
        if (v == 'tv') unawaited(_playOnTv());
        if (v == 'open') unawaited(_openExternal());
        if (v == 'session') sendToSessionPeer(context, File(file!));
        if (v == 'keys') unawaited(_showShortcuts());
      },
      itemBuilder: (_) {
        final t = TextStyle(color: cs.onSurface, fontSize: 13.5);
        return [
          if (share && ShareSession.active)
            PopupMenuItem(value: 'session', child: Text('Send to ${ShareSession.peer.value!.name}', style: t)),
          if (share) ...[
            PopupMenuItem(value: 'send', child: Text('Send to another device', style: t)),
            PopupMenuItem(value: 'tv', child: Text('Play on TV', style: t)),
            PopupMenuItem(value: 'open', child: Text('Open in another app', style: t)),
          ],
          PopupMenuItem(value: 'keys', child: Text('Keyboard shortcuts', style: t)),
        ];
      },
    );
  }

  Widget _desktopChrome() {
    return PremiumPlayerChrome(
      player: _player,
      title: _session.title,
      subtitle: _phoneSubtitle(),
      rate: _rate,
      rates: _rates,
      loop: _loop,
      muted: _muted,
      filling: _fit == BoxFit.cover,
      fullscreen: _fs,
      hasNext: _hasNext,
      hasPrevious: _queueIndex > 0,
      landscape: true,
      desktop: true,
      region: _holdControls,
      showPip: !_session.isVault,
      onPip: () => unawaited(_toggleDesktopPip()),
      onBack: () {
        if (_fs) {
          unawaited(_setFs(false));
        } else if (widget.embedded) {
          widget.onClose?.call();
        } else {
          Navigator.maybePop(context);
        }
      },
      onLock: () => setState(() {
        _locked = true;
        _chrome = false;
        _lockHint = true;
      }),
      onTools: () => unawaited(_showTools()),
      onSkip: (seconds) => unawaited(_skip(seconds)),
      onPrevious: () => unawaited(_playPrevious()),
      onNext: () => unawaited(_playNext()),
      onSetRate: (r) => unawaited(_setRate(r)),
      onLoop: () => unawaited(_toggleLoop()),
      onMute: () => unawaited(_toggleMute()),
      onFit: _cycleFit,
      onFullscreen: () => unawaited(_toggleFs()),
      onRotate: null,
      onAB: _toggleAB,
      abLabel: _markA == null ? null : (_markB == null ? 'A' : 'A-B'),
      onSleep: (m) {
        if (m == 0) {
          _clearSleep();
        } else if (m < 0) {
          _setSleepAtEnd();
        } else {
          _setSleep(m);
        }
      },
      sleepActive: _sleepMinutes != null || _sleepAtEnd,
      moreMenu: _desktopMoreMenu(),
    );
  }

  Widget _dockIcon(IconData icon, VoidCallback onPressed, String tooltip) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon),
      style: IconButton.styleFrom(
        foregroundColor: _chromeFg,
        padding: EdgeInsets.zero,
        minimumSize: const Size(40, 40),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  /// Classic PC layout, not full screen: the bars sit around the picture, so
  /// they follow the theme. Over the picture (full screen) they stay light.
  bool get _themedChrome =>
      Theme.of(context).brightness == Brightness.light && !_fs && DesktopSupport.isWindows && !_deskMinimal;
  Color get _chromeFg => _themedChrome ? Theme.of(context).colorScheme.onSurface : Colors.white;
  Color get _chromeMuted => _themedChrome ? Theme.of(context).colorScheme.onSurfaceVariant : Colors.white70;

  /// PC top bar: back, title, lock, options, send, TV, open elsewhere.
  Widget _desktopTopBar(bool narrow) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () {
              if (_fs) {
                unawaited(_setFs(false));
              } else if (widget.embedded) {
                widget.onClose?.call();
              } else {
                Navigator.maybePop(context);
              }
            },
            icon: Icon(
              Icons.arrow_back_rounded,
              color: _chromeFg,
            ),
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
                  style: TextStyle(
                    color: _chromeFg,
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
                      ? '$thisPlayerName · Space play · ←/→ seek · ↑/↓ volume · F full screen'
                      : '$thisPlayerName · Double-tap sides to skip · pinch to fill',
                  style: TextStyle(
                    color: _chromeMuted,
                    fontSize: 12,
                    height: 1.2,
                  ),
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
            icon: Icon(
              Icons.lock_outline_rounded,
              color: _chromeFg,
            ),
          ),
          IconButton(
            tooltip: 'Playback options',
            onPressed: _showTools,
            icon: Icon(
              Icons.tune_rounded,
              color: _chromeFg,
            ),
          ),
          if (narrow)
            PopupMenuButton<String>(
              tooltip: 'More',
              icon: Icon(
                Icons.more_vert_rounded,
                color: _chromeFg,
              ),
              onSelected: (v) {
                if (v == 'pip') unawaited(_playOverApps());
                if (v == 'send')
                  unawaited(
                    showSendToPhone(
                      context,
                      File(_session.filePath!),
                      _session.title,
                    ),
                  );
                if (v == 'tv') unawaited(_playOnTv());
                if (v == 'open') unawaited(_openExternal());
                if (v == 'session') sendToSessionPeer(context, File(_session.filePath!));
                if (v == 'tiktok') {
                  unawaited(offerTiktokReady(
                    context,
                    path: _session.filePath!,
                    title: _session.title,
                  ));
                }
              },
              itemBuilder: (_) => [
                if (_session.filePath != null && !_session.isVault && ShareSession.active)
                  PopupMenuItem(
                    value: 'session',
                    child: Text('Send to ${ShareSession.peer.value!.name}'),
                  ),
                if (!_session.isVault &&
                    !DesktopSupport.isWindows)
                  const PopupMenuItem(
                    value: 'pip',
                    child: Text('Play over other apps'),
                  ),
                if (_session.filePath != null &&
                    !_session.isVault) ...[
                  PopupMenuItem(
                    value: 'send',
                    child: Text('Send to another device'),
                  ),
                  PopupMenuItem(
                    value: 'tv',
                    child: Text('Play on TV'),
                  ),
                  PopupMenuItem(
                    value: 'open',
                    child: Text('Open in another app'),
                  ),
                  if (!DesktopSupport.isWindows)
                    PopupMenuItem(
                      value: 'tiktok',
                      child: Text('Make TikTok ready'),
                    ),
                ],
              ],
            ),
          if (!narrow &&
              !_session.isVault &&
              !DesktopSupport.isWindows)
            IconButton(
              tooltip: 'Play over other apps',
              onPressed: _playOverApps,
              icon: Icon(
                Icons.picture_in_picture_alt_rounded,
                color: _chromeFg,
              ),
            ),
          if (!narrow &&
              _session.filePath != null &&
              !_session.isVault)
            IconButton(
              tooltip: 'Send to another device',
              onPressed: () => unawaited(
                showSendToPhone(
                  context,
                  File(_session.filePath!),
                  _session.title,
                ),
              ),
              icon: Icon(
                Icons.send_to_mobile_rounded,
                color: _chromeFg,
              ),
            ),
          if (!narrow &&
              _session.filePath != null &&
              !_session.isVault)
            IconButton(
              tooltip: 'Play on TV',
              onPressed: () => unawaited(_playOnTv()),
              icon: Icon(
                Icons.tv_rounded,
                color: _chromeFg,
              ),
            ),
          if (!narrow &&
              _session.filePath != null &&
              !_session.isVault)
            IconButton(
              tooltip: 'Open in another app',
              onPressed: _openExternal,
              icon: Icon(
                Icons.open_in_new_rounded,
                color: _chromeFg,
              ),
            ),
        ],
      ),
    );
  }

  /// Progress bar and buttons in the black band under the picture.
  Widget _controlDock() {
    return ColoredBox(
      color: _themedChrome ? Theme.of(context).colorScheme.surface : Colors.black,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _DockSeek(player: _player, themed: _themedChrome),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _dockIcon(
                Icons.replay_10_rounded,
                () => unawaited(_skip(-10)),
                'Back 10 seconds',
              ),
              _DockPlay(player: _player, themed: _themedChrome),
              _dockIcon(
                Icons.forward_10_rounded,
                () => unawaited(_skip(10)),
                'Forward 10 seconds',
              ),
            ],
          ),
          SizedBox(
            height: 40,
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    reverse: true,
                    child: Row(
                      children: [
                        if (_queueIndex > 0)
                          _dockIcon(
                            Icons.skip_previous_rounded,
                            () => unawaited(_playPrevious()),
                            'Previous',
                          ),
                        IconButton(
                          tooltip: 'Speed ${_rateLabel(_rate)}',
                          onPressed: () => DesktopSupport.isWindows
                              ? unawaited(
                                  _rateKey(_rate >= 2 ? -(_rate - 1) : 0.25),
                                )
                              : unawaited(_showTools()),
                          style: IconButton.styleFrom(
                            foregroundColor: _chromeFg,
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(40, 40),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: Text(
                            _rateLabel(_rate),
                            style: TextStyle(
                              color: _chromeFg,
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (_hasNext)
                          _dockIcon(
                            Icons.skip_next_rounded,
                            () => unawaited(_playNext()),
                            'Next',
                          ),
                        _dockIcon(
                          _loop
                              ? Icons.repeat_one_rounded
                              : Icons.repeat_rounded,
                          () => unawaited(_toggleLoop()),
                          _loop ? 'Loop on' : 'Loop',
                        ),
                        _dockIcon(
                          _muted
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          () => unawaited(_toggleMute()),
                          _muted ? 'Unmute' : 'Mute',
                        ),
                        _dockIcon(
                          _fit == BoxFit.cover
                              ? Icons.fit_screen_rounded
                              : Icons.aspect_ratio_rounded,
                          _cycleFit,
                          _fit == BoxFit.cover
                              ? 'Fit to screen'
                              : 'Fill screen',
                        ),
                        if (!DesktopSupport.isWindows)
                          _dockIcon(
                            Icons.screen_rotation_rounded,
                            () => unawaited(_rotate()),
                            'Rotate',
                          ),
                        _dockIcon(
                          _fs
                              ? Icons.fullscreen_exit_rounded
                              : Icons.fullscreen_rounded,
                          () => unawaited(_toggleFs()),
                          _fs ? 'Exit full screen' : 'Full screen',
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Windows: desktop controls (click = play/pause, double-click = full
  /// screen, wheel = volume, cursor hides) plus our keyboard map.
  Widget _desktopVideo() {
    final keys = _desktopKeys();
    final desktop = MaterialDesktopVideoControlsThemeData(
      playAndPauseOnTap: true,
      // Double-click is ours (real window full screen).
      toggleFullscreenOnDoublePress: false,
      modifyVolumeOnScroll: true,
      hideMouseOnControlsRemoval: true,
      // Same idle time as our controls, so the cursor hides with them.
      controlsHoverDuration: Duration(seconds: _fs ? 5 : 3),
      seekBarPositionColor: AppColors.secondaryContainer,
      seekBarThumbColor: AppColors.secondaryContainer,
      // A seek that lands quickly shouldn't flash a spinner.
      bufferingIndicatorBuilder: (_) => const _DelayedSpinner(),
      // The progress bar and buttons sit in the black area under the picture.
      displaySeekBar: false,
      bottomButtonBar: const [],
      // Keys are handled once, by our CallbackShortcuts above, so they
      // work no matter which child has focus.
      keyboardShortcuts: const {},
    );
    _keyMap = keys;
    return Builder(
      builder: (_) => Focus(
        focusNode: _keyFocus,
        autofocus: true,
        // PC: player buttons never hold keyboard focus, so Space can't also
        // press a focused button; keys are handled once, globally.
        descendantsAreFocusable: false,
        onKeyEvent: (node, event) {
          final kb = HardwareKeyboard.instance;
          for (final a in _keyMap.keys) {
            if (a.accepts(event, kb)) return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
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
                controls: _locked
                    ? _hiddenControls
                    : MaterialDesktopVideoControls,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Gestures stay on the picture. The buttons and progress bar do not.
  MaterialVideoControlsThemeData _theme() {
    return const MaterialVideoControlsThemeData(
      displaySeekBar: false,
      seekOnDoubleTap: true,
      seekGesture: true,
      volumeGesture: true,
      brightnessGesture: true,
      speedUpOnLongPress: false,
      speedUpFactor: 2,
      visibleOnMount: false,
      backdropColor: Color(0x00000000),
      primaryButtonBar: [],
      topButtonBar: [],
      bottomButtonBar: [],
      buttonBarHeight: 0,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelCountdown();
    _chromeTimer?.cancel();
    _seekTimer?.cancel();
    _osdTimer?.cancel();
    if (DesktopSupport.isWindows) {
      HardwareKeyboard.instance.removeHandler(_onHardwareKey);
      InAppPlayerScreen.openCount--;
      windowManager.removeListener(this);
    }
    _keyFocus.dispose();
    _sleepTimer?.cancel();
    if (_fs || _forceLandscape) {
      if (DesktopSupport.isWindows) {
        unawaited(
          _mkChannel
              .invokeMethod<void>('Utils.ExitNativeFullscreen')
              .catchError((_) {}),
        );
      } else {
        unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
        unawaited(SystemChrome.setPreferredOrientations(const []));
      }
    }
    PlaybackBridge.clear(this);
    unawaited(
      PhoneBody.setPlayback(
        active: false,
        playing: false,
        title: _session.title,
        headset: false,
        volumeSeek: false,
      ),
    );
    if (_dimmed) unawaited(PhoneBody.setBrightness(-1));
    unawaited(_saveResume());
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    PipController.setAllowed(false);
    PipController.clearListener();
    if (DesktopPip.active) unawaited(DesktopPip.exit());
    WakelockPlus.disable();
    DeviceMediaService().setSecure(false);
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = _theme();
    final Widget video = DesktopSupport.isWindows
        ? _desktopVideo()
        : MaterialVideoControlsTheme(
            normal: theme,
            fullscreen: theme,
            child: Video(
              controller: _video,
              fill: Colors.black,
              fit: _fit,
              subtitleViewConfiguration: SubtitlePrefs.config(),
              controls: _locked || _inPip
                  ? _hiddenControls
                  : MaterialVideoControls,
            ),
          );

    if (_inPip) {
      final pictureOnly = _FittedVideo(
        width: _frameWidth,
        height: _frameHeight,
        child: Video(
          controller: _video,
          fill: Colors.black,
          fit: BoxFit.contain,
          controls: null,
        ),
      );
      if (!DesktopSupport.isWindows) {
        return Scaffold(backgroundColor: Colors.black, body: pictureOnly);
      }
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            pictureOnly,
            DesktopPipControls(
              player: _player,
              onExpand: () => unawaited(_toggleDesktopPip()),
              onClose: () async {
                // Closing the mini player stops the video.
                _closingPip = true;
                await _player.pause();
                await _toggleDesktopPip();
                if (!mounted) return;
                if (widget.embedded) {
                  widget.onClose?.call();
                } else {
                  unawaited(Navigator.maybePop(context));
                }
              },
            ),
          ],
        ),
      );
    }

    final phone = !DesktopSupport.isWindows;
    final narrow = MediaQuery.sizeOf(context).width < 560;
    // 1.0.45: when nothing is drawn yet (error) or the classic PC bars sit
    // around the picture, the page follows the theme. The picture itself
    // (and full screen) stays black.
    final cs = Theme.of(context).colorScheme;
    final themedPage = Theme.of(context).brightness == Brightness.light &&
        !_fs &&
        (_error != null || _themedChrome);
    return PopScope(
      // Back leaves full screen first.
      // Leaving a playing video on the PC goes to picture in picture.
      // Decided at Back time (play state is not part of this build).
      canPop: !_fs && !_mayAutoPip,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_fs) {
          unawaited(_setFs(false));
        } else if (_autoPipReady()) {
          unawaited(_toggleDesktopPip());
        } else {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: themedPage ? cs.surface : Colors.black,
        body: MouseRegion(
          // PC full screen: the cursor hides with the controls.
          cursor: DesktopSupport.isWindows && _fs && !_chrome && !_overControls
              ? SystemMouseCursors.none
              : MouseCursor.defer,
          child: Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerUp,
          onPointerSignal: _onPointerSignal,
          // PC: moving the mouse brings the controls back (also in full screen).
          onPointerHover: (_) {
            if (DesktopSupport.isWindows) _showChrome();
          },
          child: SafeArea(
            top: !_fs,
            bottom: !_fs,
            left: !_fs,
            right: !_fs,
            child: Column(
              children: [
                // Always laid out (only faded) so showing it never shifts the video:
                // the shift moved the seek bar under the mouse mid-click and the
                // click then seeked to 0:00.
                if (!phone && !_fs && !_deskMinimal)
                  Visibility(
                    visible: _chrome || _showEndCard,
                    maintainSize: true,
                    maintainAnimation: true,
                    maintainState: true,
                    child: _holdControls(_desktopTopBar(narrow), 'top'),
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
                                  style: TextStyle(
                                    color: themedPage ? cs.onSurfaceVariant : Colors.white70,
                                    fontSize: 16,
                                    height: 1.4,
                                  ),
                                ),
                                if (_session.filePath != null &&
                                    !_session.isVault) ...[
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
                      else if (phone)
                        _phoneStage(video)
                      else if (_deskMinimal)
                        Stack(
                          fit: StackFit.expand,
                          children: [
                            _videoHero(video),
                            IgnorePointer(
                              ignoring: _locked || (!_chrome && !_showEndCard),
                              child: AnimatedOpacity(
                                opacity: !_locked && (_chrome || _showEndCard) ? 1 : 0,
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOutCubic,
                                child: _desktopChrome(),
                              ),
                            ),
                          ],
                        )
                      else
                        _VideoStage(
                          width: _frameWidth,
                          height: _frameHeight,
                          dock: IgnorePointer(
                            ignoring: _locked || (!_chrome && !_showEndCard),
                            child: AnimatedOpacity(
                              opacity: !_locked && (_chrome || _showEndCard)
                                  ? 1
                                  : 0,
                              duration: const Duration(milliseconds: 180),
                              child: _holdControls(_controlDock(), 'dock'),
                            ),
                          ),
                          child: _videoHero(video),
                        ),
                      // PC full screen: the same top bar floats over the picture
                      // and hides with the other controls.
                      if (!phone && _fs && !_locked && _error == null && !_deskMinimal)
                        Positioned(
                          left: 0,
                          right: 0,
                          top: 0,
                          child: IgnorePointer(
                            ignoring: !_chrome && !_showEndCard,
                            child: AnimatedOpacity(
                              opacity: _chrome || _showEndCard ? 1 : 0,
                              duration: const Duration(milliseconds: 180),
                              child: DecoratedBox(
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [Color(0xCC000000), Color(0x00000000)],
                                  ),
                                ),
                                child: _holdControls(_desktopTopBar(narrow), 'top'),
                              ),
                            ),
                          ),
                        ),
                      if (_locked) _lockLayer(phone),
                      _osdLayer(),
                      if (_showEndCard)
                        _EndCard(
                          countdown: _countdown,
                          hasNext: _hasNext,
                          nextTitle: _hasNext
                              ? _queue[_queueIndex + 1].title
                              : null,
                          autoNext: ref
                              .watch(settingsControllerProvider)
                              .autoPlayNextInGallery,
                          onRewatch: () => unawaited(_rewatch()),
                          onPlayNext: _hasNext
                              ? () => unawaited(_playNext())
                              : null,
                        ),
                    ],
                  ),
                ),
                if (!_ready && _error == null)
                  // Quiet hairline while the file opens.
                  LinearProgressIndicator(
                    minHeight: 2,
                    color: themedPage ? cs.primary : const Color(0xB3FFFFFF),
                    backgroundColor: themedPage ? cs.primary.withValues(alpha: 0.12) : const Color(0x14FFFFFF),
                  ),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }
}

/// Picture on top, controls in the black band directly underneath.
class _VideoStage extends StatelessWidget {
  const _VideoStage({
    required this.child,
    required this.dock,
    this.width,
    this.height,
  });

  final Widget child;
  final Widget dock;
  final int? width;
  final int? height;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final frameW = width ?? 0;
        final frameH = height ?? 0;
        final layout = VideoStageLayout.compute(
          maxWidth: constraints.maxWidth,
          maxHeight: constraints.maxHeight,
          aspect: frameW > 0 && frameH > 0 ? frameW / frameH : 9 / 16,
        );
        return Stack(
          children: [
            Positioned(
              left: layout.videoLeft,
              top: layout.videoTop,
              width: layout.videoWidth,
              height: layout.videoHeight,
              child: child,
            ),
            Positioned(
              left: 0,
              right: 0,
              top: layout.dockTop,
              height: layout.dockHeight,
              child: dock,
            ),
          ],
        );
      },
    );
  }
}

class _DockPlay extends StatefulWidget {
  const _DockPlay({required this.player, this.themed = false});

  final Player player;
  final bool themed;

  @override
  State<_DockPlay> createState() => _DockPlayState();
}

class _DockPlayState extends State<_DockPlay> {
  StreamSubscription<bool>? _sub;
  late bool _playing;

  @override
  void initState() {
    super.initState();
    _playing = widget.player.state.playing;
    _sub = widget.player.stream.playing.listen((value) {
      if (mounted) setState(() => _playing = value);
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: _playing ? 'Pause' : 'Play',
      onPressed: () => unawaited(widget.player.playOrPause()),
      iconSize: 36,
      color: widget.themed ? Theme.of(context).colorScheme.onSurface : Colors.white,
      icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
    );
  }
}

class _DockSeek extends StatefulWidget {
  const _DockSeek({required this.player, this.themed = false});

  final Player player;
  final bool themed;

  @override
  State<_DockSeek> createState() => _DockSeekState();
}

class _DockSeekState extends State<_DockSeek> {
  final _subs = <StreamSubscription<dynamic>>[];
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  bool _dragging = false;
  double _drag = 0;
  // Dragging: quick keyframe seeks at most every 90 ms so the picture
  // follows the thumb, then one exact seek where it is let go.
  Duration? _scrubTarget;
  DateTime? _lastScrub;
  Timer? _scrubTimer;

  @override
  void initState() {
    super.initState();
    final player = widget.player;
    _position = player.state.position;
    _duration = player.state.duration;
    _buffer = player.state.buffer;
    _subs.add(
      player.stream.position.listen((value) {
        if (!mounted || _dragging) return;
        setState(() => _position = value);
      }),
    );
    _subs.add(
      player.stream.duration.listen((value) {
        if (!mounted) return;
        setState(() => _duration = value);
      }),
    );
    _subs.add(
      player.stream.buffer.listen((value) {
        if (!mounted) return;
        setState(() => _buffer = value);
      }),
    );
  }

  @override
  void dispose() {
    _scrubTimer?.cancel();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  void _apply(double dx, double width, {bool drag = false}) {
    if (width <= 0 || _duration <= Duration.zero) return;
    final fraction = (dx / width).clamp(0.0, 1.0);
    final target = _duration * fraction;
    setState(() {
      _dragging = true;
      _drag = fraction;
      _position = target;
    });
    if (!drag) {
      unawaited(widget.player.seek(target));
      return;
    }
    _scrubTarget = target;
    final now = DateTime.now();
    final since = _lastScrub == null
        ? const Duration(days: 1)
        : now.difference(_lastScrub!);
    const gap = Duration(milliseconds: 90);
    if (since >= gap) {
      _scrubTimer?.cancel();
      _scrubTimer = null;
      _fastSeek(target);
    } else {
      _scrubTimer ??= Timer(gap - since, () {
        _scrubTimer = null;
        final t = _scrubTarget;
        if (t != null && _dragging) _fastSeek(t);
      });
    }
  }

  void _fastSeek(Duration target) {
    _lastScrub = DateTime.now();
    try {
      // NativePlayer (libmpv) is not part of the web build; call it loosely.
      final dynamic native = widget.player.platform;
      unawaited(
        native.command([
          'seek',
          (target.inMilliseconds / 1000).toStringAsFixed(3),
          'absolute+keyframes',
        ]) as Future<void>,
      );
    } catch (_) {
      unawaited(widget.player.seek(target));
    }
  }

  void _endDrag() {
    _scrubTimer?.cancel();
    _scrubTimer = null;
    final t = _scrubTarget;
    _scrubTarget = null;
    _lastScrub = null;
    if (t != null) unawaited(widget.player.seek(t));
    setState(() => _dragging = false);
  }

  String _clock(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
    }
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final total = _duration.inMilliseconds;
    final fraction = total <= 0
        ? 0.0
        : (_position.inMilliseconds / total).clamp(0.0, 1.0);
    final buffered = total <= 0
        ? 0.0
        : (_buffer.inMilliseconds / total).clamp(0.0, 1.0);
    final cs = Theme.of(context).colorScheme;
    final fg = widget.themed ? cs.onSurface : Colors.white;
    final muted = widget.themed ? cs.onSurfaceVariant : Colors.white70;
    return Row(
      children: [
        SizedBox(
          width: 56,
          child: Text(
            _clock(_position),
            textAlign: TextAlign.right,
            style: TextStyle(color: fg, fontSize: 12),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) =>
                    _apply(details.localPosition.dx, constraints.maxWidth),
                onHorizontalDragStart: (details) => _apply(
                  details.localPosition.dx,
                  constraints.maxWidth,
                  drag: true,
                ),
                onHorizontalDragUpdate: (details) => _apply(
                  details.localPosition.dx,
                  constraints.maxWidth,
                  drag: true,
                ),
                onHorizontalDragEnd: (_) => _endDrag(),
                onHorizontalDragCancel: _endDrag,
                onTapUp: (_) => setState(() => _dragging = false),
                child: SizedBox(
                  height: 28,
                  child: CustomPaint(
                    painter: _SeekPainter(
                      fraction: _dragging ? _drag : fraction,
                      buffer: buffered,
                      color: widget.themed ? cs.primary : AppColors.secondaryContainer,
                      base: fg,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 56,
          child: Text(
            _clock(_duration),
            style: TextStyle(color: muted, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _SeekPainter extends CustomPainter {
  const _SeekPainter({
    required this.fraction,
    required this.buffer,
    required this.color,
    this.base = Colors.white,
  });

  final double fraction;
  final double buffer;
  final Color color;
  final Color base;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final track = Paint()
      ..color = base.withValues(alpha: 0.24)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final buffered = Paint()
      ..color = base.withValues(alpha: 0.4)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final played = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), track);
    canvas.drawLine(Offset(0, y), Offset(size.width * buffer, y), buffered);
    canvas.drawLine(Offset(0, y), Offset(size.width * fraction, y), played);
    canvas.drawCircle(
      Offset(size.width * fraction, y),
      6,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _SeekPainter oldDelegate) {
    return oldDelegate.fraction != fraction ||
        oldDelegate.buffer != buffer ||
        oldDelegate.color != color ||
        oldDelegate.base != base;
  }
}

class _FittedVideo extends StatelessWidget {
  const _FittedVideo({required this.child, this.width, this.height});

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
        child: AspectRatio(aspectRatio: aspect, child: child),
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

/// What the docked player's full-screen page hands back when it closes.
class _FsHandBack {
  const _FsHandBack({
    required this.position,
    required this.playing,
    required this.queueIndex,
    required this.rate,
    required this.volume,
  });

  final Duration position;
  final bool playing;
  final int queueIndex;
  final double rate;
  final double volume;
}

/// Buffering spinner that only appears if the wait lasts over 300 ms.
class _DelayedSpinner extends StatefulWidget {
  const _DelayedSpinner();

  @override
  State<_DelayedSpinner> createState() => _DelayedSpinnerState();
}

class _DelayedSpinnerState extends State<_DelayedSpinner> {
  bool _show = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
    return const CircularProgressIndicator(
      color: AppColors.secondaryContainer,
    );
  }
}
