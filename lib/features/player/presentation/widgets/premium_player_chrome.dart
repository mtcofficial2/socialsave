import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Classic player controls" switch (default off = the premium controls).
class PlayerChromePrefs {
  static const _key = 'socialsave_classic_player_controls';
  static final ValueNotifier<bool> classic = ValueNotifier(false);
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    classic.value = (await SharedPreferences.getInstance()).getBool(_key) ?? false;
  }

  static Future<void> set(bool v) async {
    classic.value = v;
    await (await SharedPreferences.getInstance()).setBool(_key, v);
  }
}

class ClassicControlsSwitch extends StatelessWidget {
  const ClassicControlsSwitch({super.key, required this.onChanged});
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: PlayerChromePrefs.classic,
      builder: (context, v, _) => SwitchListTile(
        key: const ValueKey('classic-controls-switch'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('Classic player controls', style: TextStyle(color: Colors.white)),
        subtitle: const Text('Turn on to bring back the old look', style: TextStyle(color: Colors.white54, fontSize: 12)),
        value: v,
        onChanged: (x) async {
          await PlayerChromePrefs.set(x);
          onChanged();
        },
      ),
    );
  }
}

String _clock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  final ss = s.toString().padLeft(2, "0");
  if (h > 0) return "${h}:${m.toString().padLeft(2, "0")}:${ss}";
  return "${m}:${ss}";
}

const _tabular = [FontFeature.tabularFigures()];

/// Frosted glass surface used by every control.
class _Glass extends StatelessWidget {
  const _Glass({required this.child, this.radius = 24, this.padding = EdgeInsets.zero, this.strong = false});
  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: strong ? 0.22 : 0.12),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Premium phone player controls: glass top bar, big centre cluster, a glowing
/// seek bar with a time bubble, and a pill toolbar of chips.
class PremiumPlayerChrome extends StatelessWidget {
  const PremiumPlayerChrome({
    super.key,
    required this.player,
    required this.title,
    required this.subtitle,
    required this.rate,
    required this.rates,
    required this.loop,
    required this.muted,
    required this.filling,
    required this.fullscreen,
    required this.hasNext,
    required this.landscape,
    required this.onBack,
    required this.onLock,
    required this.onTools,
    required this.onSkip,
    required this.onPrevious,
    required this.onNext,
    required this.onSetRate,
    required this.onLoop,
    required this.onMute,
    required this.onFit,
    required this.onFullscreen,
    required this.onRotate,
    required this.onAB,
    required this.abLabel,
    required this.onSleep,
    required this.sleepActive,
    this.onSend,
    this.showPip = false,
    this.onPip,
    this.moreMenu,
  });

  final Player player;
  final String title;
  final String subtitle;
  final double rate;
  final List<double> rates;
  final bool loop;
  final bool muted;
  final bool filling;
  final bool fullscreen;
  final bool hasNext;
  final bool landscape;
  final VoidCallback onBack;
  final VoidCallback onLock;
  final VoidCallback onTools;
  final void Function(int seconds) onSkip;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final void Function(double rate) onSetRate;
  final VoidCallback onLoop;
  final VoidCallback onMute;
  final VoidCallback onFit;
  final VoidCallback onFullscreen;
  final VoidCallback onRotate;
  final VoidCallback onAB;
  final String? abLabel;
  final void Function(int minutes) onSleep;
  final bool sleepActive;
  final VoidCallback? onSend;
  final bool showPip;
  final VoidCallback? onPip;
  final Widget? moreMenu;

  String _rateText(double r) => r == r.roundToDouble() ? '${r.toStringAsFixed(0)}x' : '${r}x';

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final big = landscape ? 60.0 : 76.0;
    return Stack(
      children: [
        IgnorePointer(
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xCC000000), Color(0x00000000), Color(0x00000000), Color(0xE6000000)],
                stops: [0, 0.28, 0.55, 1],
              ),
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, landscape ? 4 : 8, 12, landscape ? 6 : 12),
            child: Column(
              children: [
                _top(context),
                Expanded(
                  child: Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _round(Icons.skip_previous_rounded, 'Previous video', onPrevious, 48),
                        SizedBox(width: landscape ? 12 : 10),
                        _round(Icons.replay_10_rounded, 'Rewind 10 seconds', () => onSkip(-10), landscape ? 48 : 52),
                        SizedBox(width: landscape ? 16 : 14),
                        _PlayButton(player: player, size: big, accent: accent),
                        SizedBox(width: landscape ? 16 : 14),
                        _round(Icons.forward_10_rounded, 'Forward 10 seconds', () => onSkip(10), landscape ? 48 : 52),
                        SizedBox(width: landscape ? 12 : 10),
                        Opacity(
                          opacity: hasNext ? 1 : 0.4,
                          child: _round(Icons.skip_next_rounded, 'Next video', hasNext ? onNext : () {}, 48),
                        ),
                      ],
                    ),
                  ),
                ),
                _PremiumSeek(player: player, accent: accent),
                const SizedBox(height: 8),
                _toolbar(context, accent),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _round(IconData icon, String label, VoidCallback onTap, double size) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: _Glass(
          radius: size,
          child: SizedBox(width: size, height: size, child: Icon(icon, color: Colors.white, size: size * 0.55)),
        ),
      ),
    );
  }

  Widget _glassIcon(IconData icon, String label, VoidCallback onTap, {Color? color}) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: _Glass(
          radius: 22,
          child: SizedBox(width: 48, height: 48, child: Icon(icon, color: color ?? Colors.white, size: 22)),
        ),
      ),
    );
  }

  Widget _top(BuildContext context) {
    return Row(
      children: [
        _glassIcon(Icons.arrow_back_rounded, 'Back', onBack),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: 0.1, height: 1.2),
              ),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12, height: 1.3),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (onSend != null) ...[_glassIcon(Icons.send_rounded, 'Send this video', onSend!), const SizedBox(width: 8)],
        _glassIcon(Icons.closed_caption_rounded, 'Captions and audio', onTools),
        if (moreMenu != null) ...[
          const SizedBox(width: 8),
          _Glass(radius: 22, child: SizedBox(width: 48, height: 48, child: Center(child: moreMenu))),
        ],
      ],
    );
  }

  Widget _chip({required IconData icon, required String label, required String semantics, VoidCallback? onTap, bool active = false, required Color accent}) {
    final c = active ? accent : Colors.white;
    return Semantics(
      button: true,
      label: semantics,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap();
              },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: active ? accent.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: c),
              if (label.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(label, style: TextStyle(color: c, fontSize: 12.5, fontWeight: FontWeight.w700, fontFeatures: _tabular)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context, Color accent) {
    final speedChip = PopupMenuButton<double>(
      tooltip: 'Playback speed',
      color: const Color(0xFF1E1E22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      onSelected: onSetRate,
      itemBuilder: (_) => [
        for (final r in rates)
          CheckedPopupMenuItem<double>(
            value: r,
            checked: (r - rate).abs() < 0.01,
            child: Text(_rateText(r), style: const TextStyle(color: Colors.white)),
          ),
      ],
      child: _chip(icon: Icons.speed_rounded, label: _rateText(rate), semantics: 'Playback speed ${_rateText(rate)}', active: (rate - 1).abs() > 0.01, accent: accent),
    );
    final sleepChip = PopupMenuButton<int>(
      tooltip: 'Sleep timer',
      color: const Color(0xFF1E1E22),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      onSelected: onSleep,
      itemBuilder: (_) => const [
        PopupMenuItem(value: 0, child: Text('Off', style: TextStyle(color: Colors.white))),
        PopupMenuItem(value: 15, child: Text('15 minutes', style: TextStyle(color: Colors.white))),
        PopupMenuItem(value: 30, child: Text('30 minutes', style: TextStyle(color: Colors.white))),
        PopupMenuItem(value: 60, child: Text('1 hour', style: TextStyle(color: Colors.white))),
        PopupMenuItem(value: -1, child: Text('End of video', style: TextStyle(color: Colors.white))),
      ],
      child: _chip(icon: sleepActive ? Icons.bedtime_rounded : Icons.bedtime_outlined, label: sleepActive ? 'On' : 'Sleep', semantics: 'Sleep timer', active: sleepActive, accent: accent),
    );
    return _Glass(
      radius: 28,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            speedChip,
            _chip(icon: filling ? Icons.crop_free_rounded : Icons.fit_screen_rounded, label: filling ? 'Fill' : 'Fit', semantics: filling ? 'Aspect: fill. Tap for fit' : 'Aspect: fit. Tap for fill', onTap: onFit, accent: accent),
            _chip(icon: Icons.lock_outline_rounded, label: 'Lock', semantics: 'Lock controls', onTap: onLock, accent: accent),
            _chip(icon: Icons.screen_rotation_rounded, label: 'Rotate', semantics: 'Rotate screen', onTap: onRotate, accent: accent),
            if (showPip && onPip != null) _chip(icon: Icons.picture_in_picture_alt_rounded, label: 'PiP', semantics: 'Picture in picture', onTap: onPip, accent: accent),
            _chip(icon: Icons.repeat_rounded, label: abLabel ?? 'A-B', semantics: 'A to B repeat', onTap: onAB, active: abLabel != null, accent: accent),
            sleepChip,
            _chip(icon: loop ? Icons.repeat_one_rounded : Icons.repeat_rounded, label: 'Loop', semantics: loop ? 'Loop on' : 'Loop off', onTap: onLoop, active: loop, accent: accent),
            _chip(icon: muted ? Icons.volume_off_rounded : Icons.volume_up_rounded, label: '', semantics: muted ? 'Unmute' : 'Mute', onTap: onMute, active: muted, accent: accent),
            _chip(icon: Icons.queue_music_rounded, label: 'More', semantics: 'Playlist and playback settings', onTap: onTools, accent: accent),
            _chip(icon: fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, label: '', semantics: fullscreen ? 'Exit full screen' : 'Full screen', onTap: onFullscreen, accent: accent),
          ],
        ),
      ),
    );
  }
}

class _PlayButton extends StatefulWidget {
  const _PlayButton({required this.player, required this.size, required this.accent});
  final Player player;
  final double size;
  final Color accent;

  @override
  State<_PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<_PlayButton> {
  StreamSubscription<bool>? _sub;
  late bool _playing = widget.player.state.playing;
  bool _down = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.player.stream.playing.listen((v) {
      if (mounted) setState(() => _playing = v);
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return Semantics(
      button: true,
      label: _playing ? 'Pause' : 'Play',
      excludeSemantics: true,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: () {
          HapticFeedback.mediumImpact();
          unawaited(widget.player.playOrPause());
        },
        child: AnimatedScale(
          scale: _down ? 0.92 : (_playing ? 1.0 : 1.04),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutBack,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: widget.accent.withValues(alpha: 0.45), blurRadius: 36, spreadRadius: 2)],
            ),
            child: _Glass(
              radius: s,
              strong: true,
              child: SizedBox(
                width: s,
                height: s,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOutBack,
                  transitionBuilder: (c, a) => ScaleTransition(scale: a, child: FadeTransition(opacity: a, child: c)),
                  child: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded, key: ValueKey(_playing), color: Colors.white, size: s * 0.56),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PremiumSeek extends StatefulWidget {
  const _PremiumSeek({required this.player, required this.accent});
  final Player player;
  final Color accent;

  @override
  State<_PremiumSeek> createState() => _PremiumSeekState();
}

class _PremiumSeekState extends State<_PremiumSeek> {
  final _subs = <StreamSubscription<dynamic>>[];
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  Duration _buf = Duration.zero;
  double? _drag;

  @override
  void initState() {
    super.initState();
    final s = widget.player.state;
    _pos = s.position;
    _dur = s.duration;
    _buf = s.buffer;
    _subs.add(widget.player.stream.position.listen((v) {
      if (mounted && _drag == null) setState(() => _pos = v);
    }));
    _subs.add(widget.player.stream.duration.listen((v) {
      if (mounted) setState(() => _dur = v);
    }));
    _subs.add(widget.player.stream.buffer.listen((v) {
      if (mounted) setState(() => _buf = v);
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    super.dispose();
  }

  double _frac(Duration d) => _dur.inMilliseconds > 0 ? (d.inMilliseconds / _dur.inMilliseconds).clamp(0.0, 1.0) : 0.0;

  @override
  Widget build(BuildContext context) {
    final dragging = _drag != null;
    final f = _drag ?? _frac(_pos);
    final shown = dragging ? Duration(milliseconds: (_dur.inMilliseconds * f).round()) : _pos;
    final remaining = _dur - shown;
    return Semantics(
      label: 'Seek bar, ${_clock(shown)} of ${_clock(_dur)}',
      slider: true,
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) {
                  final x = (d.localPosition.dx / w).clamp(0.0, 1.0);
                  unawaited(widget.player.seek(Duration(milliseconds: (_dur.inMilliseconds * x).round())));
                },
                onHorizontalDragStart: (d) {
                  HapticFeedback.selectionClick();
                  setState(() => _drag = (d.localPosition.dx / w).clamp(0.0, 1.0));
                },
                onHorizontalDragUpdate: (d) => setState(() => _drag = (d.localPosition.dx / w).clamp(0.0, 1.0)),
                onHorizontalDragEnd: (_) {
                  final x = _drag ?? 0;
                  final target = Duration(milliseconds: (_dur.inMilliseconds * x).round());
                  setState(() {
                    _pos = target;
                    _drag = null;
                  });
                  unawaited(widget.player.seek(target));
                },
                child: SizedBox(
                  height: 56,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: CustomPaint(painter: _SeekPainter(played: f, buffered: _frac(_buf), accent: widget.accent, dragging: dragging)),
                      ),
                      Positioned(
                        left: (f * w - 30).clamp(0.0, w - 60),
                        top: 0,
                        width: 60,
                        child: AnimatedOpacity(
                          opacity: dragging ? 1 : 0,
                          duration: const Duration(milliseconds: 150),
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(color: widget.accent, borderRadius: BorderRadius.circular(14)),
                              child: Text(_clock(shown), style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 12, fontFeatures: _tabular)),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_clock(shown), style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600, fontFeatures: _tabular)),
                Text('-${_clock(remaining.isNegative ? Duration.zero : remaining)}', style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12.5, fontWeight: FontWeight.w600, fontFeatures: _tabular)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SeekPainter extends CustomPainter {
  _SeekPainter({required this.played, required this.buffered, required this.accent, required this.dragging});
  final double played;
  final double buffered;
  final Color accent;
  final bool dragging;

  @override
  void paint(Canvas canvas, Size size) {
    final h = dragging ? 7.0 : 4.0;
    final y = size.height - 18;
    final track = RRect.fromLTRBR(0, y - h / 2, size.width, y + h / 2, Radius.circular(h));
    canvas.drawRRect(track, Paint()..color = Colors.white.withValues(alpha: 0.18));
    final bw = size.width * buffered.clamp(0.0, 1.0);
    canvas.drawRRect(RRect.fromLTRBR(0, y - h / 2, bw, y + h / 2, Radius.circular(h)), Paint()..color = Colors.white.withValues(alpha: 0.32));
    final pw = size.width * played.clamp(0.0, 1.0);
    final grad = Paint()
      ..shader = LinearGradient(colors: [accent.withValues(alpha: 0.7), accent]).createShader(Rect.fromLTWH(0, 0, size.width, 1));
    canvas.drawRRect(RRect.fromLTRBR(0, y - h / 2, pw, y + h / 2, Radius.circular(h)), grad);
    final r = dragging ? 11.0 : 7.0;
    canvas.drawCircle(Offset(pw, y), r + 8, Paint()..color = accent.withValues(alpha: dragging ? 0.35 : 0.22)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
    canvas.drawCircle(Offset(pw, y), r, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_SeekPainter o) => o.played != played || o.buffered != buffered || o.dragging != dragging || o.accent != accent;
}

/// Frosted pill used for the gesture HUD (brightness, volume, seek, speed).
class PlayerHudPill extends StatelessWidget {
  const PlayerHudPill({super.key, required this.text, this.icon});
  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return _Glass(
      radius: 26,
      strong: true,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, color: Colors.white, size: 26), const SizedBox(width: 10)],
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800, fontFeatures: _tabular)),
        ],
      ),
    );
  }
}