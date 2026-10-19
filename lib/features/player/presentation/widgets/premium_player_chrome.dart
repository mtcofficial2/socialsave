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

/// Faint shadow so white text stays readable on bright frames.
const _soft = [Shadow(color: Color(0x73000000), blurRadius: 8)];

/// Wraps a control region (PC: keeps the controls up while the mouse is on it).
typedef ChromeRegion = Widget Function(Widget child, String name);

/// 1.0.44 player controls, shared by Android and Windows.
///
/// Minimal by design: soft top and bottom gradients instead of panels, a
/// quiet top bar (back, title, captions, more), a centred play/pause with two
/// light skip buttons, a hairline progress bar that thickens on hover or
/// drag, and one bottom row: time on the left, speed / PiP / one overflow
/// menu / full screen on the right. Everything else lives in the overflow.
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
    this.hasPrevious = false,
    this.onSend,
    this.showPip = false,
    this.onPip,
    this.moreMenu,
    this.region,
    this.desktop = false,
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
  final bool hasPrevious;
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
  final VoidCallback? onRotate;
  final VoidCallback onAB;
  final String? abLabel;
  final void Function(int minutes) onSleep;
  final bool sleepActive;
  final VoidCallback? onSend;
  final bool showPip;
  final VoidCallback? onPip;
  final Widget? moreMenu;
  final ChromeRegion? region;
  final bool desktop;

  static String rateText(double r) {
    if (r == r.roundToDouble()) return '${r.toStringAsFixed(0)}×';
    return '${r.toString().replaceAll(RegExp(r'0+$'), '')}×';
  }

  Widget _wrap(Widget child, String name) => region == null ? child : region!(child, name);

  @override
  Widget build(BuildContext context) {
    final compact = landscape || desktop;
    final side = desktop ? 28.0 : 18.0;
    return Stack(
      children: [
        // Soft scrims only where the text sits; the picture stays clean.
        const Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x8C000000), Color(0x00000000), Color(0x00000000), Color(0xD9000000)],
                  stops: [0, 0.22, 0.52, 1],
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(side - 8, compact ? 6 : 10, side - 8, compact ? 8 : 14),
            child: Column(
              children: [
                _wrap(_top(), 'top'),
                Expanded(child: Center(child: _wrap(_centre(compact), 'centre'))),
                _wrap(_bottom(context), 'dock'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _top() {
    return Row(
      children: [
        _QuietButton(
          icon: Icons.arrow_back_ios_new_rounded,
          size: 18,
          label: 'Back',
          onTap: onBack,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.1,
                  height: 1.25,
                  shadows: _soft,
                ),
              ),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 11.5,
                    letterSpacing: 0.1,
                    height: 1.3,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        _QuietButton(icon: Icons.closed_caption_off_outlined, label: 'Subtitles and audio', onTap: onTools),
        if (moreMenu != null) SizedBox(width: 40, height: 40, child: Center(child: moreMenu)),
      ],
    );
  }

  Widget _centre(bool compact) {
    final play = compact ? 60.0 : 68.0;
    final gap = compact ? 40.0 : 34.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _QuietButton(icon: Icons.replay_10_rounded, size: 28, box: 52, label: 'Back 10 seconds', onTap: () => onSkip(-10)),
        SizedBox(width: gap),
        _PlayButton(player: player, size: play),
        SizedBox(width: gap),
        _QuietButton(icon: Icons.forward_10_rounded, size: 28, box: 52, label: 'Forward 10 seconds', onTap: () => onSkip(10)),
      ],
    );
  }

  Widget _bottom(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _MinimalSeek(player: player),
        ),
        Row(
          children: [
            const SizedBox(width: 8),
            _TimeLabel(player: player),
            const Spacer(),
            if (hasPrevious) _QuietButton(icon: Icons.skip_previous_rounded, label: 'Previous video', onTap: onPrevious),
            if (hasNext) _QuietButton(icon: Icons.skip_next_rounded, label: 'Next video', onTap: onNext),
            _speedButton(),
            if (showPip && onPip != null)
              _QuietButton(icon: Icons.picture_in_picture_alt_outlined, label: 'Picture in picture', onTap: onPip!),
            _overflow(context),
            _QuietButton(
              icon: fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
              size: 24,
              label: fullscreen ? 'Exit full screen' : 'Full screen',
              onTap: onFullscreen,
            ),
          ],
        ),
      ],
    );
  }

  Widget _speedButton() {
    final changed = (rate - 1).abs() > 0.01;
    return _MinimalMenu<double>(
      tooltip: 'Playback speed',
      onSelected: onSetRate,
      items: [
        for (final r in rates)
          _MenuEntry(value: r, label: rateText(r), checked: (r - rate).abs() < 0.01),
      ],
      child: SizedBox(
        height: 40,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Center(
            child: Text(
              rateText(rate),
              style: TextStyle(
                color: changed ? Colors.white : Colors.white.withValues(alpha: 0.8),
                fontSize: 13,
                fontWeight: changed ? FontWeight.w700 : FontWeight.w500,
                fontFeatures: _tabular,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _overflow(BuildContext context) {
    return _MinimalMenu<String>(
      tooltip: 'More',
      onSelected: (v) {
        switch (v) {
          case 'loop':
            onLoop();
          case 'mute':
            onMute();
          case 'fit':
            onFit();
          case 'lock':
            onLock();
          case 'ab':
            onAB();
          case 'rotate':
            onRotate?.call();
          case 'send':
            onSend?.call();
          case 'tools':
            onTools();
          case 'sleep0':
            onSleep(0);
          case 'sleep15':
            onSleep(15);
          case 'sleep30':
            onSleep(30);
          case 'sleep60':
            onSleep(60);
          case 'sleepEnd':
            onSleep(-1);
        }
      },
      items: [
        _MenuEntry(value: 'loop', label: 'Loop', icon: loop ? Icons.repeat_one_rounded : Icons.repeat_rounded, checked: loop),
        _MenuEntry(value: 'mute', label: muted ? 'Unmute' : 'Mute', icon: muted ? Icons.volume_off_outlined : Icons.volume_up_outlined),
        _MenuEntry(value: 'fit', label: filling ? 'Fit to screen' : 'Fill screen', icon: filling ? Icons.fit_screen_outlined : Icons.crop_free_rounded),
        _MenuEntry(value: 'ab', label: abLabel == null ? 'Repeat A to B' : (abLabel == 'A' ? 'Set point B' : 'Clear A to B'), icon: Icons.repeat_rounded, checked: abLabel != null),
        _MenuEntry(value: 'lock', label: 'Lock controls', icon: Icons.lock_outline_rounded),
        if (onRotate != null) _MenuEntry(value: 'rotate', label: 'Rotate', icon: Icons.screen_rotation_outlined),
        if (onSend != null) _MenuEntry(value: 'send', label: 'Send this video', icon: Icons.send_outlined),
        const _MenuEntry.divider(),
        _MenuEntry.header(sleepActive ? 'Sleep timer · on' : 'Sleep timer'),
        const _MenuEntry(value: 'sleep15', label: '15 minutes', indent: true),
        const _MenuEntry(value: 'sleep30', label: '30 minutes', indent: true),
        const _MenuEntry(value: 'sleep60', label: '1 hour', indent: true),
        const _MenuEntry(value: 'sleepEnd', label: 'End of video', indent: true),
        if (sleepActive) const _MenuEntry(value: 'sleep0', label: 'Turn off', indent: true),
        const _MenuEntry.divider(),
        const _MenuEntry(value: 'tools', label: 'Playlist, subtitles and audio', icon: Icons.tune_rounded),
      ],
      child: const SizedBox(
        width: 40,
        height: 40,
        child: Icon(Icons.more_horiz_rounded, color: Colors.white, size: 22),
      ),
    );
  }
}

/// Icon without a plate. A faint circle appears on hover or press.
class _QuietButton extends StatefulWidget {
  const _QuietButton({required this.icon, required this.label, required this.onTap, this.size = 22, this.box = 40});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final double size;
  final double box;

  @override
  State<_QuietButton> createState() => _QuietButtonState();
}

class _QuietButtonState extends State<_QuietButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final lit = _hover || _down;
    return Tooltip(
      message: widget.label,
      waitDuration: const Duration(milliseconds: 600),
      child: Semantics(
        button: true,
        label: widget.label,
        excludeSemantics: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _down = true),
            onTapCancel: () => setState(() => _down = false),
            onTapUp: (_) => setState(() => _down = false),
            onTap: () {
              HapticFeedback.selectionClick();
              widget.onTap();
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              width: widget.box,
              height: widget.box,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: lit ? 0.10 : 0),
              ),
              child: AnimatedScale(
                scale: _down ? 0.9 : 1,
                duration: const Duration(milliseconds: 120),
                child: Icon(widget.icon, color: Colors.white.withValues(alpha: lit ? 1 : 0.88), size: widget.size),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuEntry<T> {
  const _MenuEntry({required T this.value, required this.label, this.icon, this.checked = false, this.indent = false})
      : kind = 0;
  const _MenuEntry.divider()
      : value = null,
        label = '',
        icon = null,
        checked = false,
        indent = false,
        kind = 1;
  const _MenuEntry.header(this.label)
      : value = null,
        icon = null,
        checked = false,
        indent = false,
        kind = 2;
  final T? value;
  final String label;
  final IconData? icon;
  final bool checked;
  final bool indent;
  final int kind;
}

/// Dark, rounded popup used by the speed and overflow buttons.
class _MinimalMenu<T> extends StatelessWidget {
  const _MinimalMenu({required this.items, required this.onSelected, required this.child, required this.tooltip});
  final List<_MenuEntry<dynamic>> items;
  final void Function(T value) onSelected;
  final Widget child;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    const text = TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w500);
    return PopupMenuButton<T>(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      color: const Color(0xF2161619),
      elevation: 12,
      shadowColor: Colors.black,
      surfaceTintColor: Colors.transparent,
      position: PopupMenuPosition.over,
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 260),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final e in items)
          if (e.kind == 1)
            const PopupMenuDivider(height: 9)
          else if (e.kind == 2)
            PopupMenuItem<T>(
              enabled: false,
              height: 30,
              child: Text(
                e.label.toUpperCase(),
                style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 10.5, fontWeight: FontWeight.w600, letterSpacing: 0.8),
              ),
            )
          else
            PopupMenuItem<T>(
              value: e.value as T,
              height: 40,
              child: Row(
                children: [
                  if (e.icon != null) ...[
                    Icon(e.icon, size: 18, color: Colors.white.withValues(alpha: 0.75)),
                    const SizedBox(width: 12),
                  ] else if (e.indent)
                    const SizedBox(width: 2),
                  Expanded(child: Text(e.label, style: text)),
                  if (e.checked) const Icon(Icons.check_rounded, size: 16, color: Colors.white),
                ],
              ),
            ),
      ],
      child: child,
    );
  }
}

class _PlayButton extends StatefulWidget {
  const _PlayButton({required this.player, required this.size});
  final Player player;
  final double size;

  @override
  State<_PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<_PlayButton> {
  StreamSubscription<bool>? _sub;
  late bool _playing = widget.player.state.playing;
  bool _down = false;
  bool _hover = false;

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
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: () {
            HapticFeedback.lightImpact();
            unawaited(widget.player.playOrPause());
          },
          child: AnimatedScale(
            scale: _down ? 0.92 : (_hover ? 1.04 : 1.0),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: ClipOval(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: s,
                  height: s,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: _hover ? 0.18 : 0.12),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.16), width: 0.8),
                  ),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (c, a) => FadeTransition(
                      opacity: a,
                      child: ScaleTransition(scale: Tween(begin: 0.8, end: 1.0).animate(a), child: c),
                    ),
                    child: Icon(
                      _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      key: ValueKey(_playing),
                      color: Colors.white,
                      size: s * 0.5,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "1:23 / 4:56" in tabular figures; the total is dimmer.
class _TimeLabel extends StatefulWidget {
  const _TimeLabel({required this.player});
  final Player player;

  @override
  State<_TimeLabel> createState() => _TimeLabelState();
}

class _TimeLabelState extends State<_TimeLabel> {
  final _subs = <StreamSubscription<dynamic>>[];
  late Duration _pos = widget.player.state.position;
  late Duration _dur = widget.player.state.duration;

  @override
  void initState() {
    super.initState();
    _subs.add(widget.player.stream.position.listen((v) {
      if (mounted && v.inSeconds != _pos.inSeconds) setState(() => _pos = v);
    }));
    _subs.add(widget.player.stream.duration.listen((v) {
      if (mounted) setState(() => _dur = v);
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: _clock(_pos), style: const TextStyle(color: Colors.white)),
          TextSpan(text: '  /  ${_clock(_dur)}', style: TextStyle(color: Colors.white.withValues(alpha: 0.5))),
        ],
      ),
      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, fontFeatures: _tabular, letterSpacing: 0.2, shadows: _soft),
    );
  }
}

/// Hairline progress bar. It thickens and shows a thumb on hover (PC) or
/// while dragging, with a small time label above the pointer.
class _MinimalSeek extends StatefulWidget {
  const _MinimalSeek({required this.player});
  final Player player;

  @override
  State<_MinimalSeek> createState() => _MinimalSeekState();
}

class _MinimalSeekState extends State<_MinimalSeek> {
  final _subs = <StreamSubscription<dynamic>>[];
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  Duration _buf = Duration.zero;
  double? _drag;
  double? _hoverX;

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
  Duration _at(double f) => Duration(milliseconds: (_dur.inMilliseconds * f).round());

  @override
  Widget build(BuildContext context) {
    final dragging = _drag != null;
    final active = dragging || _hoverX != null;
    final f = _drag ?? _frac(_pos);
    return Semantics(
      label: 'Seek bar, ${_clock(_at(f))} of ${_clock(_dur)}',
      slider: true,
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          double x(double dx) => (dx / w).clamp(0.0, 1.0);
          final labelF = _drag ?? (_hoverX == null ? null : x(_hoverX!));
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            onHover: (e) => setState(() => _hoverX = e.localPosition.dx),
            onExit: (_) => setState(() => _hoverX = null),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                final target = _at(x(d.localPosition.dx));
                setState(() => _pos = target);
                unawaited(widget.player.seek(target));
              },
              onHorizontalDragStart: (d) {
                HapticFeedback.selectionClick();
                setState(() => _drag = x(d.localPosition.dx));
              },
              onHorizontalDragUpdate: (d) => setState(() => _drag = x(d.localPosition.dx)),
              onHorizontalDragEnd: (_) {
                final target = _at(_drag ?? 0);
                setState(() {
                  _pos = target;
                  _drag = null;
                });
                unawaited(widget.player.seek(target));
              },
              onHorizontalDragCancel: () => setState(() => _drag = null),
              child: SizedBox(
                height: 34,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(end: active ? 1 : 0),
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOut,
                        builder: (context, t, _) => CustomPaint(
                          painter: _SeekPainter(
                            played: f,
                            buffered: _frac(_buf),
                            hover: _hoverX == null || dragging ? null : x(_hoverX!),
                            t: t,
                          ),
                        ),
                      ),
                    ),
                    if (labelF != null)
                      Positioned(
                        left: (labelF * w - 28).clamp(0.0, (w - 56).clamp(0.0, double.infinity)),
                        top: -18,
                        width: 56,
                        child: Center(
                          child: Text(
                            _clock(_at(labelF)),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              fontFeatures: _tabular,
                              shadows: [Shadow(color: Color(0x99000000), blurRadius: 6)],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SeekPainter extends CustomPainter {
  _SeekPainter({required this.played, required this.buffered, required this.hover, required this.t});
  final double played;
  final double buffered;
  final double? hover;
  final double t; // 0 idle .. 1 hovered/dragging

  @override
  void paint(Canvas canvas, Size size) {
    final h = 3.0 + 2.0 * t;
    final y = size.height / 2;
    final r = Radius.circular(h);
    RRect bar(double to) => RRect.fromLTRBR(0, y - h / 2, size.width * to.clamp(0.0, 1.0), y + h / 2, r);
    canvas.drawRRect(bar(1), Paint()..color = Colors.white.withValues(alpha: 0.20));
    canvas.drawRRect(bar(buffered), Paint()..color = Colors.white.withValues(alpha: 0.30));
    if (hover != null && hover! > played) {
      canvas.drawRRect(
        RRect.fromLTRBR(size.width * played, y - h / 2, size.width * hover!, y + h / 2, r),
        Paint()..color = Colors.white.withValues(alpha: 0.22),
      );
    }
    canvas.drawRRect(bar(played), Paint()..color = Colors.white);
    final thumb = 6.5 * t;
    if (thumb > 0.5) {
      final c = Offset(size.width * played.clamp(0.0, 1.0), y);
      canvas.drawCircle(c, thumb + 2, Paint()..color = Colors.black.withValues(alpha: 0.25)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
      canvas.drawCircle(c, thumb, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(_SeekPainter o) => o.played != played || o.buffered != buffered || o.hover != hover || o.t != t;
}

/// Quiet pill for the gesture HUD (brightness, volume, seek, speed).
class PlayerHudPill extends StatelessWidget {
  const PlayerHudPill({super.key, required this.text, this.icon});
  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, color: Colors.white, size: 20), const SizedBox(width: 10)],
              Text(
                text,
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0.1, fontFeatures: _tabular),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
