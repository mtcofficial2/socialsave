import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/shared/widgets/app_snack.dart';
import 'package:social_save/core/diagnostics/quiet_log.dart';
import 'package:social_save/core/theme/app_tokens.dart';
import 'package:social_save/features/chat/chat_ui.dart';

typedef ChatRecView = ({int ms, List<double> levels, bool paused});

/// A voice note kept on this phone after it has been sent or played.
class ChatVoiceFiles {
  static bool _safe(String id) => RegExp(r'^[a-z0-9]+$').hasMatch(id);

  static String _ext(String type) {
    switch (type) {
      case 'wav':
        return 'wav';
      case 'ogg':
        return 'ogg';
      case 'webm':
        return 'webm';
      default:
        return 'm4a';
    }
  }

  static Future<File?> existing(String id, String type) async {
    if (!_safe(id)) return null;
    final file = await _place(id, type);
    if (!await file.exists()) return null;
    return file;
  }

  static Future<void> save(String id, String type, Uint8List bytes) async {
    if (!_safe(id) || bytes.isEmpty) return;
    final file = await _place(id, type);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  static Future<File> _place(String id, String type) async {
    final root = await getApplicationDocumentsDirectory();
    return File(p.join(root.path, 'chat-voices', '$id.${_ext(type)}'));
  }
}

/// Tap-to-record voice notes. Hold-to-record fights scrolling on a phone.
class ChatRecorder {
  AudioRecorder? _recorder;
  Timer? _tick;
  DateTime? _started;
  // Counts only the time the microphone is really recording: it stops while
  // paused and is read before the file is finalised, so the length sent with
  // the note matches the audio instead of including start/stop delays.
  final Stopwatch _clock = Stopwatch();
  final List<double> _samples = [];
  // Every level of this take (the live view keeps only the last 48).
  final List<double> _take = [];
  bool _reading = false;
  bool _limitSent = false;
  bool recording = false;
  bool paused = false;
  int shownMs = 0;
  void Function()? onLimit;

  final ValueNotifier<ChatRecView> view = ValueNotifier((ms: 0, levels: const <double>[], paused: false));

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
    paused = false;
    _limitSent = false;
    shownMs = 0;
    _samples.clear();
    _take.clear();
    _started = DateTime.now();
    _clock
      ..reset()
      ..start();
    _publish();
    _tick?.cancel();
    _tick = Timer.periodic(AppDurations.fast, (_) => unawaited(_sample()));
    return null;
  }

  Future<void> togglePause() async {
    final recorder = _recorder;
    if (!recording || recorder == null) return;
    try {
      if (paused) {
        await recorder.resume();
        _clock.start();
        _started = DateTime.now().subtract(Duration(milliseconds: _clock.elapsedMilliseconds));
        paused = false;
      } else {
        await recorder.pause();
        _clock.stop();
        shownMs = _clock.elapsedMilliseconds;
        paused = true;
      }
    } catch (e) { logQuiet('chat_voice', e); }
    _publish();
  }

  Future<void> _sample() async {
    if (!recording || paused || _reading) return;
    final started = _started;
    final recorder = _recorder;
    if (started == null || recorder == null) return;
    shownMs = _clock.elapsedMilliseconds;
    if (shownMs >= 60000) {
      shownMs = 60000;
      _publish();
      if (!_limitSent) {
        _limitSent = true;
        onLimit?.call();
      }
      return;
    }
    _reading = true;
    try {
      final amp = await recorder.getAmplitude();
      final level = _level(amp.current);
      _samples.add(level);
      _take.add(level);
      if (_samples.length > 48) _samples.removeAt(0);
    } catch (_) {
      _samples.add(0.16);
      if (_samples.length > 48) _samples.removeAt(0);
    } finally {
      _reading = false;
    }
    if (recording) _publish();
  }

  void _publish() {
    view.value = (ms: shownMs, levels: List<double>.from(_samples), paused: paused);
  }

  Future<({String path, int ms, String levels})?> stop({required bool send}) async {
    _tick?.cancel();
    _tick = null;
    _clock.stop();
    final recordedMs = _clock.elapsedMilliseconds;
    final started = _started;
    _started = null;
    recording = false;
    paused = false;
    final recorder = _recorder;
    if (recorder == null) return null;
    if (!send) {
      try {
        await recorder.cancel();
      } catch (e) { logQuiet('chat_voice', e); }
      _samples.clear();
      _take.clear();
      shownMs = 0;
      _publish();
      return null;
    }
    String? path;
    try {
      path = await recorder.stop();
    } catch (_) {
      path = null;
    }
    final ms = started == null ? shownMs : recordedMs;
    final levels = encodeVoiceLevels(_take);
    _samples.clear();
    _take.clear();
    shownMs = 0;
    _publish();
    if (path == null || path.isEmpty) return null;
    return (path: path, ms: ms, levels: levels);
  }

  Future<void> dispose() async {
    _tick?.cancel();
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      if (recording) {
        try {
          await recorder.cancel();
        } catch (e) { logQuiet('chat_voice', e); }
      }
      await recorder.dispose();
    }
    recording = false;
    paused = false;
    view.dispose();
  }
}

double _level(double db) {
  if (db.isNaN || db < -50) return 0.16;
  final scaled = (db + 46) / 38;
  if (scaled < 0.16) return 0.16;
  if (scaled > 1) return 1;
  return scaled;
}

/// Squeezes a take's loudness (0.0-1.0 per sample) into at most [bars]
/// digits 0-9, averaging neighbours, so it fits in one small header.
String encodeVoiceLevels(List<double> samples, {int bars = 48}) {
  if (samples.isEmpty || bars <= 0) return '';
  final count = samples.length < bars ? samples.length : bars;
  final out = StringBuffer();
  for (var i = 0; i < count; i++) {
    final start = (i * samples.length / count).floor();
    var end = ((i + 1) * samples.length / count).floor();
    if (end <= start) end = start + 1;
    var sum = 0.0;
    for (var j = start; j < end; j++) {
      sum += samples[j];
    }
    final avg = (sum / (end - start)).clamp(0.0, 1.0);
    out.write((avg * 9).round());
  }
  return out.toString();
}

/// Bar heights (0.2-1.0) from [encodeVoiceLevels] output, stretched or
/// squeezed to [count] bars. Returns an empty list when [code] is not valid.
List<double> decodeVoiceLevels(String code, int count) {
  if (count <= 0 || code.isEmpty || !RegExp(r'^[0-9]+$').hasMatch(code)) {
    return const [];
  }
  final raw = [for (final unit in code.codeUnits) (unit - 48) / 9.0];
  return List<double>.generate(count, (index) {
    final at = (index * raw.length / count).floor().clamp(0, raw.length - 1);
    return (0.2 + raw[at] * 0.8).clamp(0.2, 1.0);
  });
}

/// The bars a voice bubble draws: the real recording when the note carries
/// its levels, otherwise a stable made-up shape for older notes.
List<double> voiceBarsFor({required String levels, required String seed, required int count}) {
  final real = decodeVoiceLevels(levels, count);
  return real.isNotEmpty ? real : voiceBars(seed, count);
}

/// Stable bar heights for a voice note. The same id always draws the same shape.
List<double> voiceBars(String seed, int count) {
  if (count <= 0) return const [];
  var hash = 2166136261;
  for (final unit in seed.codeUnits) {
    hash = 0x7fffffff & (hash ^ unit) * 16777619;
  }
  return List<double>.generate(count, (index) {
    hash = 0x7fffffff & (hash ^ (index + 1)) * 16777619;
    final pick = (hash % 1000) / 1000.0;
    return (0.2 + pick * 0.8).clamp(0.2, 1.0);
  });
}

class ChatRecordingBar extends StatelessWidget {
  const ChatRecordingBar({
    super.key,
    required this.view,
    required this.onDelete,
    required this.onSend,
    required this.onPause,
  });

  final ValueNotifier<ChatRecView> view;
  final VoidCallback onDelete;
  final VoidCallback onSend;
  final VoidCallback onPause;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<ChatRecView>(
      valueListenable: view,
      builder: (context, rec, _) {
        return Row(
          children: [
            IconButton(
              tooltip: 'Delete',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_rounded, color: Color(0xFFEF5350)),
            ),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: AppRadii.xlAll,
                ),
                child: SizedBox(
                  height: 48,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 14, right: AppSpacing.md),
                    child: Row(
                      children: [
                        _RecDot(paused: rec.paused),
                        const SizedBox(width: AppSpacing.sm),
                        Text(
                          chatClock(rec.ms),
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: scheme.onSurface,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: CustomPaint(
                            painter: _BarsPainter(
                              levels: rec.levels,
                              progress: 1,
                              played: scheme.onSurfaceVariant,
                              rest: scheme.onSurfaceVariant,
                              fromEnd: true,
                              showThumb: false,
                            ),
                            child: const SizedBox(height: 28),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.xxs),
            IconButton(
              tooltip: rec.paused ? 'Resume' : 'Pause',
              onPressed: onPause,
              icon: Icon(rec.paused ? Icons.mic_rounded : Icons.pause_rounded),
            ),
            IconButton.filled(
              tooltip: 'Send voice note',
              style: IconButton.styleFrom(backgroundColor: ChatUiTokens.brand, foregroundColor: Colors.white),
              onPressed: onSend,
              icon: const Icon(Icons.send_rounded),
            ),
          ],
        );
      },
    );
  }
}

class _RecDot extends StatefulWidget {
  const _RecDot({required this.paused});

  final bool paused;

  @override
  State<_RecDot> createState() => _RecDotState();
}

class _RecDotState extends State<_RecDot> with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))
    ..repeat(reverse: true);

  @override
  void didUpdateWidget(_RecDot old) {
    super.didUpdateWidget(old);
    if (widget.paused) {
      _blink.stop();
      _blink.value = 1;
    } else if (!_blink.isAnimating) {
      _blink.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0.25).animate(_blink),
      child: const DecoratedBox(
        decoration: BoxDecoration(color: Color(0xFFFF3B30), shape: BoxShape.circle),
        child: SizedBox(width: 9, height: 9),
      ),
    );
  }
}

class _VoicePaint {
  const _VoicePaint({required this.button, required this.icon, required this.played, required this.rest, required this.meta});

  final Color button;
  final Color icon;
  final Color played;
  final Color rest;
  final Color meta;

  factory _VoicePaint.of({required bool mine, required bool dark}) {
    const green = Color(0xFF00A884);
    final meta = ChatUiTokens.time(dark);
    if (mine && !dark) {
      return _VoicePaint(button: Colors.white, icon: ChatUiTokens.brandDeep, played: ChatUiTokens.brandDeep, rest: const Color(0xFF8EB8A8), meta: meta);
    }
    if (mine && dark) {
      return _VoicePaint(button: ChatUiTokens.textDark, icon: ChatUiTokens.outgoingDark, played: ChatUiTokens.textDark, rest: const Color(0xFF6F8A82), meta: meta);
    }
    return _VoicePaint(button: green, icon: Colors.white, played: green, rest: dark ? ChatUiTokens.iconMuted : const Color(0xFFCDD5DB), meta: meta);
  }
}

class ChatVoiceBubble extends StatefulWidget {
  const ChatVoiceBubble({super.key, required this.message, required this.api, required this.mine, required this.dark});

  final ChatMessage message;
  final ChatApi api;
  final bool mine;
  final bool dark;

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
  StreamSubscription<Duration>? _durationSub;
  // The real length of the audio, as the player reports it after loading.
  Duration _duration = Duration.zero;
  // True from the end of playback until it is started again, so a late
  // position update cannot move the bar after the sound has stopped.
  bool _ended = false;
  bool _busy = false;
  bool _playing = false;
  bool _heard = false;
  bool _seeking = false;
  double? _queuedSeek;
  double _rate = 1;
  int? _pendingMs;
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
    await _durationSub?.cancel();
    final player = _player;
    _player = null;
    await player?.dispose();
  }

  Future<void> _pause() async {
    try {
      await _player?.pause();
    } catch (e) { logQuiet('chat_voice', e); }
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
    _heard = true;
    _ended = false;
    if (_player != null) {
      try {
        if (_rate != 1) await _player!.setRate(_rate);
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
      // The bar follows only the player's own position, so it moves exactly
      // as fast as the sound, at any speed, and stops when the sound stops.
      _positionSub = player.stream.position.listen((value) {
        if (!mounted || _ended || _seeking) return;
        setState(() => _position = value);
      });
      _durationSub = player.stream.duration.listen((value) {
        if (mounted && value > Duration.zero && value != _duration) {
          setState(() => _duration = value);
        }
      });
      _playingSub = player.stream.playing.listen((value) {
        if (!mounted) return;
        if (value && _ended) return;
        setState(() => _playing = value);
      });
      _doneSub = player.stream.completed.listen((done) async {
        if (!done || !mounted) return;
        setState(() {
          _ended = true;
          _playing = false;
          _position = Duration.zero;
        });
        try {
          await player.seek(Duration.zero);
          await player.pause();
        } catch (e) { logQuiet('chat_voice', e); }
      });
      _player = player;
      await player.open(Media(path));
      if (_rate != 1) await player.setRate(_rate);
      final pending = _pendingMs;
      if (pending != null && pending > 0) {
        _pendingMs = null;
        await player.seek(Duration(milliseconds: pending));
      }
    } catch (_) {
      if (mounted) _fail();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cycleRate() async {
    final next = _rate == 1 ? 1.5 : _rate == 1.5 ? 2.0 : 1.0;
    setState(() {
      _rate = next;
      _heard = true;
    });
    try {
      await _player?.setRate(next);
    } catch (e) { logQuiet('chat_voice', e); }
  }

  Future<void> _seekTo(double fraction) async {
    if (_seeking) {
      _queuedSeek = fraction;
      return;
    }
    _seeking = true;
    try {
      await _seekOnce(fraction);
    } finally {
      _seeking = false;
    }
    final queued = _queuedSeek;
    _queuedSeek = null;
    if (queued != null) await _seekTo(queued);
  }

  int get _totalMs => chatVoiceTotalMs(
        playerMs: _duration.inMilliseconds,
        sentMs: widget.message.voiceMs,
      );

  Future<void> _seekOnce(double fraction) async {
    final total = _totalMs;
    if (total <= 0) return;
    _ended = false;
    final ms = (total * fraction.clamp(0.0, 1.0)).round().clamp(0, total);
    if (mounted) setState(() => _position = Duration(milliseconds: ms));
    final player = _player;
    if (player == null) {
      _pendingMs = ms;
      await _toggle();
      return;
    }
    try {
      await player.seek(Duration(milliseconds: ms));
      if (!_playing) await player.play();
      _heard = true;
    } catch (_) {
      if (mounted) _fail();
    }
  }

  Future<String?> _file() async {
    final local = widget.message.localBytes;
    if (local != null && local.isNotEmpty) {
      final key = 'local-${widget.message.id}';
      final cached = _files[key];
      if (cached != null && File(cached).existsSync()) return cached;
      final dir = await getTemporaryDirectory();
      final ext = local.length >= 12 && String.fromCharCodes(local.take(4)) == 'RIFF' ? 'wav' : 'm4a';
      final path = '${dir.path}${Platform.pathSeparator}ss-play-$key.$ext';
      await File(path).writeAsBytes(local, flush: true);
      _files[key] = path;
      return path;
    }
    final id = widget.message.voice;
    if (id.isEmpty) return null;
    final cached = _files[id];
    if (cached != null && File(cached).existsSync()) return cached;
    final kept = await ChatVoiceFiles.existing(id, widget.message.voiceType);
    if (kept != null) {
      _files[id] = kept.path;
      return kept.path;
    }
    final bytes = await widget.api.voice(id);
    await ChatVoiceFiles.save(id, widget.message.voiceType, bytes);
    final stored = await ChatVoiceFiles.existing(id, widget.message.voiceType);
    if (stored == null) return null;
    _files[id] = stored.path;
    return stored.path;
  }

  void _fail() {
    AppSnack.error(context, 'That voice note could not be played.');
  }

  String get _rateLabel {
    if (_rate == 1.5) return '1.5×';
    if (_rate == 2) return '2×';
    return '1×';
  }

  @override
  Widget build(BuildContext context) {
    final paint = _VoicePaint.of(mine: widget.mine, dark: widget.dark);
    final totalMs = _totalMs;
    final progress = chatVoiceProgress(positionMs: _position.inMilliseconds, totalMs: totalMs);
    final shown = chatVoiceClockMs(
      positionMs: _position.inMilliseconds,
      totalMs: totalMs,
      active: _playing || _position > Duration.zero,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 3, bottom: 1),
      child: Row(
        children: [
          _PlayButton(
            busy: _busy,
            playing: _playing,
            paint: paint,
            onPressed: () => unawaited(_toggle()),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 32,
                  child: Row(
                    children: [
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final width = constraints.maxWidth;
                            final count = (width / 5).floor().clamp(14, 52);
                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapDown: width <= 0 ? null : (details) => unawaited(_seekTo(details.localPosition.dx / width)),
                              onHorizontalDragUpdate: width <= 0 ? null : (details) => unawaited(_seekTo(details.localPosition.dx / width)),
                              child: CustomPaint(
                                painter: _BarsPainter(
                                  levels: voiceBarsFor(
                                    levels: widget.message.voiceLevels,
                                    seed: widget.message.voice.isEmpty ? '${widget.message.id}' : widget.message.voice,
                                    count: count,
                                  ),
                                  progress: progress,
                                  played: paint.played,
                                  rest: paint.rest,
                                  fromEnd: false,
                                  showThumb: true,
                                ),
                                child: const SizedBox(height: AppSpacing.xxl),
                              ),
                            );
                          },
                        ),
                      ),
                      GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => unawaited(_cycleRate()),
                          child: Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text(
                              _rateLabel,
                              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: paint.played),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 1),
                Row(
                  children: [
                    Icon(Icons.mic_rounded, size: 14, color: paint.meta),
                    const SizedBox(width: AppSpacing.xxs),
                    Text(chatClock(shown), style: TextStyle(fontSize: 12, height: 1.1, color: paint.meta)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.busy, required this.playing, required this.paint, required this.onPressed});

  final bool busy;
  final bool playing;
  final _VoicePaint paint;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 42,
      height: 42,
      child: Material(
        color: paint.button,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: busy ? null : onPressed,
          customBorder: const CircleBorder(),
          child: Center(
            child: busy
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: paint.icon),
                  )
                : Padding(
                    padding: EdgeInsets.only(left: playing ? 0 : 2),
                    child: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: paint.icon,
                      size: 30,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({
    required this.levels,
    required this.progress,
    required this.played,
    required this.rest,
    required this.fromEnd,
    required this.showThumb,
  });

  final List<double> levels;
  final double progress;
  final Color played;
  final Color rest;
  final bool fromEnd;
  final bool showThumb;

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty || size.width <= 0 || size.height <= 0) return;
    const gap = 2.0;
    final count = levels.length;
    var barW = 3.0;
    var step = barW + gap;
    var span = count * step - gap;
    if (span > size.width) {
      step = size.width / count;
      barW = step * 0.62;
      span = size.width;
    }
    final origin = fromEnd ? (size.width - span).clamp(0.0, size.width) : 0.0;
    final playedPaint = Paint()
      ..color = played
      ..strokeWidth = barW
      ..strokeCap = StrokeCap.round;
    final restPaint = Paint()
      ..color = rest
      ..strokeWidth = barW
      ..strokeCap = StrokeCap.round;
    final mid = size.height / 2;
    final room = ((size.height - barW) / 2).clamp(0.0, size.height);
    for (var i = 0; i < count; i++) {
      final level = levels[i].clamp(0.18, 1.0);
      final half = room * level;
      final x = origin + i * step + barW / 2;
      final head = (i + 1) / count <= progress;
      canvas.drawLine(Offset(x, mid - half), Offset(x, mid + half), head ? playedPaint : restPaint);
    }
    if (!showThumb) return;
    final thumbX = (origin + progress.clamp(0.0, 1.0) * span).clamp(5.0, size.width - 5);
    canvas.drawCircle(Offset(thumbX, mid), 5, playedPaint..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(_BarsPainter old) => true;
}

/// A song kept on this phone after it has been sent or played.
class ChatSongFiles {
  static bool _safe(String id) => RegExp(r'^[a-z0-9]+$').hasMatch(id);

  static String _ext(String type) {
    switch (type) {
      case 'flac':
        return 'flac';
      case 'ogg':
        return 'ogg';
      case 'wav':
        return 'wav';
      case 'm4a':
      case 'mp4':
        return 'm4a';
      default:
        return 'mp3';
    }
  }

  static Future<File?> existing(String id, String type) async {
    if (!_safe(id)) return null;
    final file = await _place(id, type);
    if (!await file.exists()) return null;
    return file;
  }

  static Future<void> save(String id, String type, Uint8List bytes) async {
    if (!_safe(id) || bytes.isEmpty) return;
    final file = await _place(id, type);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  static Future<File> _place(String id, String type) async {
    final root = await getApplicationDocumentsDirectory();
    return File(p.join(root.path, 'chat-songs', '$id.${_ext(type)}'));
  }
}

class ChatSongBubble extends StatefulWidget {
  const ChatSongBubble({
    super.key,
    required this.message,
    required this.api,
    required this.mine,
    required this.dark,
  });

  final ChatMessage message;
  final ChatApi api;
  final bool mine;
  final bool dark;

  @override
  State<ChatSongBubble> createState() => _ChatSongBubbleState();
}

class _ChatSongBubbleState extends State<ChatSongBubble> {
  static _ChatSongBubbleState? _active;

  Player? _player;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _doneSub;
  bool _busy = false;
  bool _playing = false;

  @override
  void dispose() {
    if (_active == this) _active = null;
    unawaited(_close());
    super.dispose();
  }

  Future<void> _close() async {
    await _playingSub?.cancel();
    await _doneSub?.cancel();
    final player = _player;
    _player = null;
    await player?.dispose();
  }

  Future<void> _pause() async {
    try {
      await _player?.pause();
    } catch (e) { logQuiet('chat_voice', e); }
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
      if (!mounted || path == null) {
        _fail();
        return;
      }
      final player = Player();
      _playingSub = player.stream.playing.listen((value) {
        if (mounted) setState(() => _playing = value);
      });
      _doneSub = player.stream.completed.listen((done) async {
        if (!done || !mounted) return;
        setState(() => _playing = false);
        try {
          await player.seek(Duration.zero);
          await player.pause();
        } catch (e) { logQuiet('chat_voice', e); }
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
    final local = widget.message.localBytes;
    if (local != null && local.isNotEmpty) {
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}${Platform.pathSeparator}ss-song-${widget.message.id}.bin';
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() != local.length) {
        await file.writeAsBytes(local, flush: true);
      }
      return path;
    }
    final id = widget.message.song;
    if (id.isEmpty) return null;
    final kept = await ChatSongFiles.existing(id, widget.message.songType);
    if (kept != null) return kept.path;
    final bytes = await widget.api.song(id);
    await ChatSongFiles.save(id, widget.message.songType, bytes);
    final stored = await ChatSongFiles.existing(id, widget.message.songType);
    return stored?.path;
  }

  void _fail() {
    AppSnack.error(context, 'That song could not be played.');
  }

  String get _length {
    final ms = widget.message.songMs;
    if (ms <= 0) return '';
    final total = (ms / 1000).round();
    final minutes = total ~/ 60;
    final seconds = (total % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final paint = _VoicePaint.of(mine: widget.mine, dark: widget.dark);
    final title = widget.message.songName.trim().isEmpty
        ? widget.message.text
        : widget.message.songName.trim();
    return Padding(
      padding: const EdgeInsets.only(top: 3, bottom: 1),
      child: Row(
        children: [
          _PlayButton(
            busy: _busy,
            playing: _playing,
            paint: paint,
            onPressed: () => unawaited(_toggle()),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: widget.dark
                        ? ChatUiTokens.textDark
                        : const Color(0xFF111B21),
                  ),
                ),
                Text(
                  _length.isEmpty ? 'Song' : 'Song · $_length',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: paint.meta),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The length the voice bar measures against: the player's real duration once
/// it is known, otherwise the length recorded with the note.
int chatVoiceTotalMs({required int playerMs, required int sentMs}) {
  if (playerMs > 0) return playerMs;
  return sentMs > 0 ? sentMs : 0;
}

/// How much of the bar is filled, from the player's position only.
double chatVoiceProgress({required int positionMs, required int totalMs}) {
  if (totalMs <= 0 || positionMs <= 0) return 0;
  return (positionMs / totalMs).clamp(0.0, 1.0);
}

/// The time under the bar: time left while playing or paused part-way, the
/// full length otherwise.
int chatVoiceClockMs({required int positionMs, required int totalMs, required bool active}) {
  if (!active) return totalMs;
  return (totalMs - positionMs).clamp(0, totalMs);
}
