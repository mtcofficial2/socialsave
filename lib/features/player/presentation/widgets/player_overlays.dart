import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/features/player/presentation/widgets/premium_player_chrome.dart';

/// Rounded, blurred bottom sheet shell with a grab handle.
class PlayerGlassSheet extends StatelessWidget {
  const PlayerGlassSheet({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final maxH = MediaQuery.sizeOf(context).height * 0.88;
    return Theme(
      data: theme.copyWith(
        chipTheme: ChipThemeData(
          backgroundColor: Colors.white.withValues(alpha: 0.08),
          selectedColor: accent.withValues(alpha: 0.35),
          side: BorderSide.none,
          shape: const StadiumBorder(),
          labelStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          secondaryLabelStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          checkmarkColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        ),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            constraints: BoxConstraints(maxHeight: maxH),
            decoration: BoxDecoration(
              color: const Color(0xE60F1014),
              border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.14))),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(4)),
                ),
                const SizedBox(height: 6),
                Flexible(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PlayerSectionHeader extends StatelessWidget {
  const PlayerSectionHeader(this.title, this.icon, {super.key});
  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Semantics(
        header: true,
        child: Row(
          children: [
            Icon(icon, size: 16, color: Colors.white54),
            const SizedBox(width: 8),
            Text(
              title.toUpperCase(),
              style: const TextStyle(color: Colors.white54, fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 1.1),
            ),
          ],
        ),
      ),
    );
  }
}

/// Listens to raw touches over the picture (it never takes them away from the
/// player) to show the accumulating "+10s" feedback and the 2x badge, and to
/// run the long-press 2x speed itself.
class PlayerGestureLayer extends StatefulWidget {
  const PlayerGestureLayer({
    super.key,
    required this.child,
    required this.onBoost,
    this.onTap,
    this.onGesture,
  });
  final Widget child;
  final void Function(bool on) onBoost;

  /// A plain single tap (not a drag, hold or double-tap).
  final VoidCallback? onTap;

  /// Any gesture started (drag, pinch, hold, double-tap): hide the controls.
  final VoidCallback? onGesture;

  @override
  State<PlayerGestureLayer> createState() => _PlayerGestureLayerState();
}

class _PlayerGestureLayerState extends State<PlayerGestureLayer> {
  Offset? _down;
  bool _moved = false;
  bool _boost = false;
  DateTime? _lastTap;
  Offset _lastPos = Offset.zero;
  Timer? _hold;
  Timer? _hide;
  Timer? _tapT;
  final Set<int> _ptrs = <int>{};
  int _seconds = 0;
  int _dir = 0;
  int _rippleId = 0;
  Offset _ripple = Offset.zero;
  bool _label = false;

  @override
  void dispose() {
    _hold?.cancel();
    _hide?.cancel();
    _tapT?.cancel();
    super.dispose();
  }

  void _onDown(PointerDownEvent e) {
    _ptrs.add(e.pointer);
    if (_ptrs.length > 1) {
      // Pinch: never a tap, and the controls get out of the way.
      _moved = true;
      _hold?.cancel();
      _tapT?.cancel();
      widget.onGesture?.call();
      return;
    }
    _down = e.localPosition;
    _moved = false;
    _hold?.cancel();
    _hold = Timer(const Duration(milliseconds: 450), () {
      if (!mounted || _moved || _down == null) return;
      widget.onGesture?.call();
      HapticFeedback.mediumImpact();
      setState(() => _boost = true);
      widget.onBoost(true);
    });
  }

  void _onMove(PointerMoveEvent e) {
    final d = _down;
    if (d != null && (e.localPosition - d).distance > 24) {
      if (!_moved) {
        _tapT?.cancel();
        widget.onGesture?.call();
      }
      _moved = true;
      _hold?.cancel();
    }
  }

  void _onUp(PointerUpEvent e) {
    _ptrs.remove(e.pointer);
    _hold?.cancel();
    if (_boost) {
      setState(() => _boost = false);
      widget.onBoost(false);
      _down = null;
      _lastTap = null;
      return;
    }
    final wasMoved = _moved;
    _down = null;
    if (wasMoved) {
      _lastTap = null;
      return;
    }
    final now = DateTime.now();
    final last = _lastTap;
    if (last != null && now.difference(last) < const Duration(milliseconds: 320) && (e.localPosition - _lastPos).distance < 90) {
      _lastTap = null;
      _tapT?.cancel();
      widget.onGesture?.call();
      _double(e.localPosition);
    } else {
      _lastTap = now;
      _lastPos = e.localPosition;
      _tapT?.cancel();
      // Wait out the double-tap window, then it is a plain tap: toggle controls.
      _tapT = Timer(const Duration(milliseconds: 330), () {
        if (mounted) widget.onTap?.call();
      });
    }
  }

  void _onCancel(PointerCancelEvent e) {
    _ptrs.remove(e.pointer);
    _hold?.cancel();
    if (_boost) {
      setState(() => _boost = false);
      widget.onBoost(false);
    }
    _down = null;
  }

  void _double(Offset p) {
    final w = context.size?.width ?? 400;
    final dir = p.dx < w * 0.35 ? -1 : (p.dx > w * 0.65 ? 1 : 0);
    if (dir == 0) return;
    setState(() {
      _seconds = (_label && _dir == dir) ? _seconds + 10 : 10;
      _dir = dir;
      _label = true;
      _ripple = p;
      _rippleId++;
    });
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _label = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          IgnorePointer(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_label)
                  Positioned(
                    left: _ripple.dx - 90,
                    top: _ripple.dy - 90,
                    width: 180,
                    height: 180,
                    child: TweenAnimationBuilder<double>(
                      key: ValueKey(_rippleId),
                      tween: Tween(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeOutCubic,
                      builder: (context, t, _) => Opacity(
                        opacity: (1 - t) * 0.6,
                        child: Container(
                          margin: EdgeInsets.all(90 * (1 - t) * 0.6),
                          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.35)),
                        ),
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment(_dir < 0 ? -0.7 : 0.7, 0),
                  child: AnimatedOpacity(
                    opacity: _label ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: AnimatedScale(
                      scale: _label ? 1 : 0.85,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutBack,
                      child: PlayerHudPill(
                        text: '${_dir < 0 ? '-' : '+'}${_seconds}s',
                        icon: _dir < 0 ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: const Alignment(0, -0.78),
                  child: AnimatedOpacity(
                    opacity: _boost ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: AnimatedSlide(
                      offset: _boost ? Offset.zero : const Offset(0, -0.4),
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(22),
                          boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.5), blurRadius: 18)],
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.fast_forward_rounded, size: 18, color: Colors.black),
                            SizedBox(width: 6),
                            Text('2x', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 15)),
                          ],
                        ),
                      ),
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
}

/// One-time, dismissible tip about the touch gestures.
class PlayerFirstHint extends StatelessWidget {
  const PlayerFirstHint({super.key, required this.onDismiss});
  final VoidCallback onDismiss;
  static const _key = 'player.hint.seen.v1';

  static Future<bool> shouldShow() async {
    try {
      return !((await SharedPreferences.getInstance()).getBool(_key) ?? false);
    } catch (_) {
      return false;
    }
  }

  static Future<void> markSeen() async {
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, true);
    } catch (_) {}
  }

  Widget _row(IconData icon, String title, String body) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
                Text(body, style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13, height: 1.3)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Semantics(
        label: 'Player gesture tips. Tap to dismiss.',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onDismiss,
          child: Container(
            color: const Color(0x99000000),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(22, 22, 22, 16),
                    decoration: BoxDecoration(
                      color: const Color(0xCC15161C),
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Quick gestures', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 8),
                          _row(Icons.touch_app_rounded, 'Double-tap', 'Left or right side skips 10 seconds.'),
                          _row(Icons.swap_vert_rounded, 'Swipe up or down', 'Left side is brightness, right side is volume.'),
                          _row(Icons.fast_forward_rounded, 'Press and hold', 'Plays at 2x until you let go.'),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton(
                              style: FilledButton.styleFrom(minimumSize: const Size(96, 48)),
                              onPressed: onDismiss,
                              child: const Text('Got it'),
                            ),
                          ),
                        ],
                      ),
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