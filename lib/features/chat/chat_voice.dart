import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_format.dart';

/// Tap-to-record voice notes. Hold-to-record fights scrolling on a phone.
class ChatRecorder {
  AudioRecorder? _recorder;
  Timer? _tick;
  DateTime? _started;
  bool recording = false;
  int shownMs = 0;
  void Function()? onTick;

  Future<String?> begin() async {
    if (recording || Plat.isWeb) return 'Voice notes are not available here.';
    final recorder = _recorder ??= AudioRecorder();
    var allowed = false;
    try {
      allowed = await recorder.hasPermission();
    } catch (_) {
      allowed = false;
    }
    if (!allowed && Plat.isAndroid) {
      allowed = (await Permission.microphone.request()).isGranted;
    }
    if (!allowed) return 'Allow the microphone to send a voice note.';
    final aac = await recorder.isEncoderSupported(AudioEncoder.aacLc);
    final encoder = aac ? AudioEncoder.aacLc : AudioEncoder.wav;
    final ext = aac ? 'm4a' : 'wav';
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}${Platform.pathSeparator}ss-voice-${DateTime.now().millisecondsSinceEpoch}.$ext';
    try {
      await recorder.start(
        RecordConfig(encoder: encoder, bitRate: 64000, sampleRate: 44100, numChannels: 1),
        path: path,
      );
    } catch (_) {
      return 'The microphone is not available.';
    }
    recording = true;
    shownMs = 0;
    _started = DateTime.now();
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      shownMs += 1000;
      onTick?.call();
    });
    return null;
  }

  Future<({String path, int ms})?> stop({required bool send}) async {
    _tick?.cancel();
    _tick = null;
    final started = _started;
    _started = null;
    recording = false;
    final recorder = _recorder;
    if (recorder == null) return null;
    if (!send) {
      try {
        await recorder.cancel();
      } catch (_) {}
      return null;
    }
    String? path;
    try {
      path = await recorder.stop();
    } catch (_) {
      path = null;
    }
    if (path == null || path.isEmpty) return null;
    final ms = started == null ? shownMs : DateTime.now().difference(started).inMilliseconds;
    return (path: path, ms: ms);
  }

  Future<void> dispose() async {
    _tick?.cancel();
    final recorder = _recorder;
    _recorder = null;
    if (recorder == null) return;
    if (recording) {
      try {
        await recorder.cancel();
      } catch (_) {}
    }
    recording = false;
    await recorder.dispose();
  }
}

class ChatVoiceBubble extends StatefulWidget {
  const ChatVoiceBubble({super.key, required this.message, required this.color, required this.api});

  final ChatMessage message;
  final Color color;
  final ChatApi api;

  @override
  State<ChatVoiceBubble> createState() => _ChatVoiceBubbleState();
}

class _ChatVoiceBubbleState extends State<ChatVoiceBubble> {
  static _ChatVoiceBubbleState? _active;
  static final Map<String, String> _files = {};

  Player? _player;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _doneSub;
  bool _busy = false;
  bool _playing = false;
  Duration _position = Duration.zero;

  @override
  void dispose() {
    if (_active == this) _active = null;
    unawaited(_close());
    super.dispose();
  }

  Future<void> _close() async {
    await _positionSub?.cancel();
    await _playingSub?.cancel();
    await _doneSub?.cancel();
    final player = _player;
    _player = null;
    await player?.dispose();
  }

  Future<void> _pause() async {
    try {
      await _player?.pause();
    } catch (_) {}
    if (mounted) setState(() => _playing = false);
  }

  Future<void> _toggle() async {
    if (_busy) return;
    if (_playing) {
      await _pause();
      return;
    }
    final previous = _active;
    if (previous != null && previous != this) await previous._pause();
    _active = this;
    if (_player != null) {
      try {
        await _player!.play();
      } catch (_) {
        if (mounted) _fail();
      }
      return;
    }
    setState(() => _busy = true);
    try {
      final path = await _file();
      if (!mounted || path == null) return;
      final player = Player();
      _positionSub = player.stream.position.listen((value) {
        if (mounted) setState(() => _position = value);
      });
      _playingSub = player.stream.playing.listen((value) {
        if (mounted) setState(() => _playing = value);
      });
      _doneSub = player.stream.completed.listen((done) async {
        if (!done || !mounted) return;
        setState(() {
          _playing = false;
          _position = Duration.zero;
        });
        try {
          await player.seek(Duration.zero);
          await player.pause();
        } catch (_) {}
      });
      _player = player;
      await player.open(Media(path));
    } catch (_) {
      if (mounted) _fail();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _file() async {
    final id = widget.message.voice;
    final cached = _files[id];
    if (cached != null && File(cached).existsSync()) return cached;
    final bytes = await widget.api.voice(id);
    final dir = await getTemporaryDirectory();
    final ext = switch (widget.message.voiceType) {
      'wav' => 'wav',
      'ogg' => 'ogg',
      'webm' => 'webm',
      _ => 'm4a',
    };
    final path = '${dir.path}${Platform.pathSeparator}ss-play-$id.$ext';
    await File(path).writeAsBytes(bytes, flush: true);
    _files[id] = path;
    return path;
  }

  void _fail() {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That voice note could not be played.')));
  }

  @override
  Widget build(BuildContext context) {
    final totalMs = widget.message.voiceMs <= 0 ? 1 : widget.message.voiceMs;
    final progress = (_position.inMilliseconds / totalMs).clamp(0.0, 1.0);
    final label = _playing || _position > Duration.zero ? chatClock(_position.inMilliseconds) : chatClock(widget.message.voiceMs);
    return SizedBox(
      width: 220,
      child: Row(
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: _busy
                ? Padding(
                    padding: const EdgeInsets.all(8),
                    child: CircularProgressIndicator(strokeWidth: 2, color: widget.color),
                  )
                : IconButton(
                    tooltip: _playing ? 'Pause' : 'Play',
                    padding: EdgeInsets.zero,
                    onPressed: () => unawaited(_toggle()),
                    icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: widget.color),
                  ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: _playing || _position > Duration.zero ? progress : 0,
                    minHeight: 3,
                    backgroundColor: widget.color.withValues(alpha: 0.25),
                    color: widget.color,
                  ),
                ),
                const SizedBox(height: 4),
                Text(label, style: TextStyle(fontSize: 12, color: widget.color)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
