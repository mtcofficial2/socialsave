import 'dart:async';

import 'package:social_save/shared/widgets/premium_glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/widgets/liquid_glass.dart';

/// Height label such as 1080p, using the shorter side of the frame.
String? phoneResolutionLabel(int? width, int? height) {
  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  final shortSide = width < height ? width : height;
  const steps = <int>[2160, 1440, 1080, 720, 480, 360, 240];
  for (final step in steps) {
    if ((shortSide - step).abs() <= 40) return '${step}p';
  }
  return '$width×$height';
}

/// Speed badge text from the design, such as 1.0x and 1.25x.
String phoneRateLabel(double rate) {
  final hundredths = (rate * 100).round();
  if (hundredths % 10 == 0) return '${(hundredths / 100).toStringAsFixed(1)}x';
  return '${hundredths / 100}x';
}

/// Phone player chrome from the cinematic mock: header, center play
/// cluster, and the seek bar, drawn on the video.
class PhonePlayerChrome extends StatelessWidget {
  const PhonePlayerChrome({
    super.key,
    required this.player,
    required this.title,
    required this.subtitle,
    required this.platform,
    required this.rate,
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
    required this.onRate,
    required this.onLoop,
    required this.onMute,
    required this.onFit,
    required this.onFullscreen,
    this.frameWidth,
    this.frameHeight,
    this.vault = false,
    this.showPip = false,
    this.showCast = false,
    this.onPip,
    this.onCast,
    this.moreMenu,
  });

  final Player player;
  final String title;
  final String subtitle;
  final SocialPlatform platform;
  final int? frameWidth;
  final int? frameHeight;
  final double rate;
  final bool loop;
  final bool muted;
  final bool filling;
  final bool fullscreen;
  final bool hasNext;
  final bool landscape;
  final bool vault;
  final bool showPip;
  final bool showCast;
  final VoidCallback onBack;
  final VoidCallback onLock;
  final VoidCallback onTools;
  final void Function(int seconds) onSkip;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onRate;
  final VoidCallback onLoop;
  final VoidCallback onMute;
  final VoidCallback onFit;
  final VoidCallback onFullscreen;
  final VoidCallback? onPip;
  final VoidCallback? onCast;
  final Widget? moreMenu;

  static const violet = Color(0xFFCABEFF);
  static const violetDeep = Color(0xFF4D30AC);
  static const violetMid = Color(0xFF947DFF);
  static const onViolet = Color(0xFF31009A);
  static const ink = Color(0xFF1B1B1B);
  static const pill = Color(0xFF2A2A2A);

  @override
  Widget build(BuildContext context) {
    final resolution = phoneResolutionLabel(frameWidth, frameHeight);
    return Stack(
      children: [
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 128,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xF2000000),
                    Color(0x99000000),
                    Color(0x00000000),
                  ],
                  stops: [0, 0.45, 1],
                ),
              ),
              child: SizedBox.expand(),
            ),
          ),
        ),
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [
                    Color(0xF2000000),
                    Color(0xB3000000),
                    Color(0x00000000),
                  ],
                  stops: [0, 0.55, 1],
                ),
              ),
              child: SizedBox(height: 168, width: double.infinity),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            8,
            landscape ? 4 : 2,
            4,
            landscape ? 8 : 10,
          ),
          child: Column(
            children: [
              _header(),
              if (!landscape && (resolution != null || vault)) ...[
                const SizedBox(height: 2),
                _pills(resolution),
              ],
              Expanded(
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _skipButton(context, back: true),
                      SizedBox(width: landscape ? 28 : 22),
                      _PlayOrb(player: player, compact: landscape),
                      SizedBox(width: landscape ? 28 : 22),
                      _skipButton(context, back: false),
                    ],
                  ),
                ),
              ),
              _PhoneSeek(player: player, centerLabel: resolution),
              const SizedBox(height: 2),
              _actionRow(context),
            ],
          ),
        ),
      ],
    );
  }

  Widget _header() {
    return Row(
      children: [
        _iconButton(Icons.arrow_back_rounded, onBack, 'Back'),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _platformBadge(),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        height: 1.2,
                        shadows: [
                          Shadow(color: Color(0xCC000000), blurRadius: 3),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xE6C7C5D4),
                  fontSize: 11,
                  height: 1.2,
                  shadows: [Shadow(color: Color(0xCC000000), blurRadius: 3)],
                ),
              ),
            ],
          ),
        ),
        if (landscape) ...[
          _iconButton(Icons.tune_rounded, onTools, 'Playback settings'),
          _iconButton(Icons.lock_open_rounded, onLock, 'Lock controls'),
          _iconButton(
            fullscreen
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            onFullscreen,
            fullscreen ? 'Exit full screen' : 'Full screen',
            tinted: true,
          ),
        ] else ...[
          _iconButton(Icons.lock_open_rounded, onLock, 'Lock controls'),
          _iconButton(Icons.tune_rounded, onTools, 'Playback settings'),
          if (showPip)
            _iconButton(
              Icons.picture_in_picture_alt_rounded,
              onPip ?? () {},
              'Picture in picture',
            ),
          if (showCast)
            _iconButton(Icons.cast_rounded, onCast ?? () {}, 'Play on computer'),
          ?moreMenu,
        ],
      ],
    );
  }

  Widget _pills(String? resolution) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Row(
          children: [
            if (resolution != null)
              _pill(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: violet,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      resolution,
                      style: const TextStyle(
                        color: violet,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            if (vault) ...[
              const SizedBox(width: 8),
              _pill(
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.lock_rounded,
                      size: 14,
                      color: Color(0xFFC9C4D8),
                    ),
                    SizedBox(width: 4),
                    Text(
                      'Vault',
                      style: TextStyle(
                        color: Color(0xFFC9C4D8),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _pill({required Widget child}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: pill.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: child,
      ),
    );
  }

  Widget _platformBadge() {
    final color = switch (platform) {
      SocialPlatform.tiktok => const Color(0xFFEE1D52),
      SocialPlatform.instagram => const Color(0xFFE1306C),
      SocialPlatform.facebook => const Color(0xFF1877F2),
      SocialPlatform.youtube => const Color(0xFFFF0000),
      SocialPlatform.reddit => const Color(0xFFFF4500),
      SocialPlatform.pinterest => const Color(0xFFE60023),
      _ => violetDeep,
    };
    final name = switch (platform) {
      SocialPlatform.unknown ||
      SocialPlatform.web ||
      SocialPlatform.direct => null,
      _ => platform.displayName,
    };
    if (name == null) return const SizedBox.shrink();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          name,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            height: 1.1,
          ),
        ),
      ),
    );
  }

  Widget _skipButton(BuildContext context, {required bool back}) {
    final size = landscape ? 44.0 : 56.0;
    final face = Semantics(
      button: true,
      label: back ? 'Rewind 10 seconds' : 'Forward 10 seconds',
      excludeSemantics: true,
      child: SizedBox(
        width: size,
        height: size,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              back ? Icons.replay_10_rounded : Icons.forward_10_rounded,
              color: Colors.white,
              size: landscape ? 22 : 28,
            ),
            Text(
              '10s',
              style: TextStyle(
                color: violet,
                fontSize: landscape ? 8 : 9,
                fontWeight: FontWeight.w800,
                height: 1,
              ),
            ),
          ],
        ),
      ),
    );
    void tap() {
      HapticFeedback.selectionClick();
      onSkip(back ? -10 : 10);
    }
    if (LiquidGlassScope.of(context)) {
      return _GlassOrb(size: size, onTap: tap, child: face);
    }
    return ClipOval(
      child: BackdropFilter(
        filter: GlassTokens.blur(16),
        child: Material(
          color: ink.withValues(alpha: 0.62),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: tap,
            child: face,
          ),
        ),
      ),
    );
  }

  Widget _actionRow(BuildContext context) {
    return Row(
      children: [
        _iconButton(Icons.skip_previous_rounded, onPrevious, 'Previous video'),
        _speedBadge(context),
        Opacity(
          opacity: hasNext ? 1 : 0.35,
          child: _iconButton(
            Icons.skip_next_rounded,
            hasNext ? onNext : () {},
            'Next video',
          ),
        ),
        const Spacer(),
        _iconButton(
          loop ? Icons.repeat_one_rounded : Icons.repeat_rounded,
          onLoop,
          loop ? 'Loop on' : 'Repeat',
          color: loop ? violet : const Color(0xFFC9C4D8),
        ),
        _iconButton(
          muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          onMute,
          muted ? 'Unmute' : 'Volume',
          color: const Color(0xFFC9C4D8),
        ),
        _iconButton(
          filling ? Icons.aspect_ratio_rounded : Icons.fit_screen_rounded,
          onFit,
          filling ? 'Fit to screen' : 'Fill screen',
          color: const Color(0xFFC9C4D8),
        ),
        _iconButton(
          fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
          onFullscreen,
          fullscreen ? 'Exit full screen' : 'Full screen',
          tinted: true,
        ),
      ],
    );
  }

  Widget _speedBadge(BuildContext context) {
    final glass = LiquidGlassScope.of(context);
    final label = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Text(
        phoneRateLabel(rate),
        style: const TextStyle(
          color: violet,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: glass ? Colors.transparent : pill.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(999),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () {
            HapticFeedback.selectionClick();
            onRate();
          },
          child: Semantics(
            button: true,
            label: 'Playback speed ${phoneRateLabel(rate)}. Tap to change.',
            excludeSemantics: true,
            child: glass ? IosGlassPlate(dark: true, child: label) : label,
          ),
        ),
      ),
    );
  }

  Widget _iconButton(
    IconData icon,
    VoidCallback onPressed,
    String tooltip, {
    bool tinted = false,
    Color color = Colors.white,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: landscape ? 20 : 22),
      color: tinted ? violet : color,
      style: IconButton.styleFrom(
        backgroundColor: tinted ? violet.withValues(alpha: 0.16) : null,
        minimumSize: Size(landscape ? 36 : 40, landscape ? 36 : 40),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsets.zero,
      ),
    );
  }
}

class _PlayOrb extends StatefulWidget {
  const _PlayOrb({required this.player, required this.compact});

  final Player player;
  final bool compact;

  @override
  State<_PlayOrb> createState() => _PlayOrbState();
}

class _PlayOrbState extends State<_PlayOrb> {
  StreamSubscription<bool>? _sub;
  late bool _playing;
  bool _down = false;

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
    final size = widget.compact ? 52.0 : 72.0;
    final icon = AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      transitionBuilder: (child, anim) => ScaleTransition(
        scale: anim,
        child: RotationTransition(turns: Tween(begin: 0.85, end: 1.0).animate(anim), child: child),
      ),
      child: Icon(
        _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        key: ValueKey(_playing),
        color: LiquidGlassScope.of(context) ? Colors.white : Colors.black,
        size: widget.compact ? 28 : 38,
      ),
    );
    if (LiquidGlassScope.of(context)) {
      return GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: () {
          HapticFeedback.mediumImpact();
          unawaited(widget.player.playOrPause());
        },
        child: LiquidSquash(
          pressed: _down,
          child: IosGlassPlate(
            dark: true,
            shadow: true,
            child: Semantics(
              button: true,
              label: _playing ? 'Pause' : 'Play',
              child: SizedBox(width: size, height: size, child: icon),
            ),
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.bottomLeft,
          end: Alignment.topRight,
          colors: [
            PhonePlayerChrome.violetDeep,
            PhonePlayerChrome.violetMid,
            PhonePlayerChrome.violet,
          ],
        ),
        boxShadow: const [BoxShadow(color: Color(0x737C5CFF), blurRadius: 32)],
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            HapticFeedback.mediumImpact();
            unawaited(widget.player.playOrPause());
          },
          child: Semantics(
            button: true,
            label: _playing ? 'Pause' : 'Play',
            child: SizedBox(width: size, height: size, child: icon),
          ),
        ),
      ),
    );
  }
}

/// Painted play/skip circle. Replaces the live blur when liquid glass is on.
class _GlassOrb extends StatefulWidget {
  const _GlassOrb({required this.size, required this.onTap, required this.child});

  final double size;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_GlassOrb> createState() => _GlassOrbState();
}

class _GlassOrbState extends State<_GlassOrb> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      child: LiquidSquash(
        pressed: _down,
        child: IosGlassPlate(
          dark: true,
          shadow: true,
          child: SizedBox(width: widget.size, height: widget.size, child: widget.child),
        ),
      ),
    );
  }
}

class _PhoneSeek extends StatefulWidget {
  const _PhoneSeek({required this.player, this.centerLabel});

  final Player player;
  final String? centerLabel;

  @override
  State<_PhoneSeek> createState() => _PhoneSeekState();
}

class _PhoneSeekState extends State<_PhoneSeek> {
  final _subs = <StreamSubscription<dynamic>>[];
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  bool _dragging = false;
  double _drag = 0;

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
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  void _apply(double dx, double width) {
    if (width <= 0 || _duration <= Duration.zero) return;
    final fraction = (dx / width).clamp(0.0, 1.0);
    setState(() {
      _dragging = true;
      _drag = fraction;
      _position = _duration * fraction;
    });
    unawaited(widget.player.seek(_duration * fraction));
  }

  String _clock(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) return '$hours:$minutes:$seconds';
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final total = _duration.inMilliseconds;
    final fraction = total <= 0
        ? 0.0
        : (_position.inMilliseconds / total).clamp(0.0, 1.0);
    final shown = _dragging ? _drag : fraction;
    final buffered = total <= 0
        ? 0.0
        : (_buffer.inMilliseconds / total).clamp(0.0, 1.0);
    return Column(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) =>
                  _apply(details.localPosition.dx, constraints.maxWidth),
              onHorizontalDragStart: (details) =>
                  _apply(details.localPosition.dx, constraints.maxWidth),
              onHorizontalDragUpdate: (details) =>
                  _apply(details.localPosition.dx, constraints.maxWidth),
              onHorizontalDragEnd: (_) => setState(() => _dragging = false),
              onTapUp: (_) => setState(() => _dragging = false),
              child: SizedBox(
                height: 36,
                width: constraints.maxWidth,
                child: CustomPaint(
                  painter: _PhoneSeekPainter(
                    fraction: shown,
                    buffer: buffered,
                    showBubble: _dragging,
                    bubble: _clock(_position),
                  ),
                ),
              ),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                child: Text(
                  _clock(_position),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              Expanded(
                child: widget.centerLabel == null
                    ? const SizedBox.shrink()
                    : Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: PhonePlayerChrome.violetDeep.withValues(
                              alpha: 0.35,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            child: Text(
                              widget.centerLabel!,
                              style: const TextStyle(
                                color: PhonePlayerChrome.violet,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
              SizedBox(
                width: 56,
                child: Text(
                  _clock(_duration),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Color(0xFFC9C4D8),
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PhoneSeekPainter extends CustomPainter {
  const _PhoneSeekPainter({
    required this.fraction,
    required this.buffer,
    required this.showBubble,
    required this.bubble,
  });

  final double fraction;
  final double buffer;
  final bool showBubble;
  final String bubble;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height - 10;
    final track = Paint()
      ..color = const Color(0xCC2A2A2A)
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    final buffered = Paint()
      ..color = PhonePlayerChrome.violet.withValues(alpha: 0.35)
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    final played = Paint()
      ..color = PhonePlayerChrome.violet
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    final left = 8.0;
    final right = size.width - 8;
    final span = right - left;
    canvas.drawLine(Offset(left, y), Offset(right, y), track);
    canvas.drawLine(Offset(left, y), Offset(left + span * buffer, y), buffered);
    final head = left + span * fraction;
    canvas.drawLine(Offset(left, y), Offset(head, y), played);
    canvas.drawCircle(Offset(head, y), 8, Paint()..color = Colors.white);
    canvas.drawCircle(
      Offset(head, y),
      3,
      Paint()..color = PhonePlayerChrome.violetMid,
    );
    if (!showBubble) return;
    final painter = TextPainter(
      text: TextSpan(
        text: bubble,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final box = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(head, y - 22),
        width: painter.width + 12,
        height: painter.height + 6,
      ),
      const Radius.circular(8),
    );
    canvas.drawRRect(box, Paint()..color = const Color(0xE6353535));
    painter.paint(canvas, Offset(box.left + 6, box.top + 3));
  }

  @override
  bool shouldRepaint(covariant _PhoneSeekPainter oldDelegate) {
    return oldDelegate.fraction != fraction ||
        oldDelegate.buffer != buffer ||
        oldDelegate.showBubble != showBubble ||
        oldDelegate.bubble != bubble;
  }
}
