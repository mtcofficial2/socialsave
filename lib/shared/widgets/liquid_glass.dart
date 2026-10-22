import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Appearance setting for the iPhone-style lens. Missing scope means on,
/// which is the default, so a control built above the app shell still matches.
class LiquidGlassScope extends InheritedWidget {
  const LiquidGlassScope({
    super.key,
    required this.enabled,
    required super.child,
  });

  final bool enabled;

  static bool of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LiquidGlassScope>();
    return scope?.enabled ?? true;
  }

  @override
  bool updateShouldNotify(LiquidGlassScope oldWidget) => enabled != oldWidget.enabled;
}

/// Clear capsule: bright rim, top highlight, bottom reflection.
/// Nothing in the paint loops. Callers animate position or a press only.
class IosGlassPainter extends CustomPainter {
  const IosGlassPainter({required this.dark, this.radius});

  final bool dark;

  /// Null uses a stadium (half the height), which matches the tab oval.
  final double? radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final r = (radius ?? size.shortestSide / 2).clamp(0.0, size.shortestSide / 2);
    final shape = RRect.fromRectAndRadius(rect, Radius.circular(r));

    canvas.drawRRect(
      shape,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            // Dark: a smoky lighter-grey lift, never milky.
            Colors.white.withValues(alpha: dark ? 0.12 : 0.48),
            Colors.white.withValues(alpha: dark ? 0.08 : 0.12),
            Colors.white.withValues(alpha: dark ? 0.07 : 0.26),
          ],
          stops: const [0.0, 0.48, 1.0],
        ).createShader(rect),
    );

    canvas.drawRRect(
      shape,
      Paint()
        ..shader = LinearGradient(
          begin: const Alignment(-0.6, -1),
          end: const Alignment(0.4, 0.15),
          colors: [
            Colors.white.withValues(alpha: dark ? 0.06 : 0.75),
            Colors.white.withValues(alpha: dark ? 0.015 : 0.14),
            const Color(0x00FFFFFF),
          ],
          stops: const [0.0, 0.28, 0.62],
        ).createShader(rect),
    );

    canvas.save();
    canvas.clipRRect(shape);
    canvas.drawRect(
      Rect.fromLTWH(0, size.height * 0.68, size.width, size.height * 0.32),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          // Dark: a faint inner shade instead of a white bottom reflection.
          colors: [
            dark ? Colors.black.withValues(alpha: 0.18) : Colors.white.withValues(alpha: 0.38),
            dark ? const Color(0x00000000) : const Color(0x00FFFFFF),
          ],
        ).createShader(
          Rect.fromLTWH(0, size.height * 0.62, size.width, size.height * 0.38),
        ),
    );
    canvas.restore();

    final rim = shape.deflate(0.7);
    canvas.drawRRect(
      rim,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = dark ? 1.0 : 1.25
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: dark ? 0.18 : 1),
            Colors.white.withValues(alpha: dark ? 0.06 : 0.38),
            Colors.white.withValues(alpha: dark ? 0.03 : 0.72),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant IosGlassPainter oldDelegate) =>
      oldDelegate.dark != dark || oldDelegate.radius != radius;
}

/// Painted lens. No blur, so it can sit on buttons and player controls
/// without re-filtering the screen.
class IosGlassPlate extends StatelessWidget {
  const IosGlassPlate({
    super.key,
    required this.dark,
    this.radius,
    this.shadow = false,
    this.child,
  });

  final bool dark;
  final double? radius;
  final bool shadow;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final plate = ClipRRect(
      borderRadius: BorderRadius.circular(radius ?? 999),
      child: CustomPaint(
        painter: IosGlassPainter(dark: dark, radius: radius),
        child: child,
      ),
    );
    if (!shadow) return plate;
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: radius == null
            ? const StadiumBorder()
            : RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius!)),
        shadows: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.45 : 0.14),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: plate,
    );
  }
}

/// Tap target that squashes while held. Used by large custom cards.
class GlassPress extends StatefulWidget {
  const GlassPress({
    super.key,
    required this.child,
    required this.onTap,
    this.borderRadius = const BorderRadius.all(Radius.circular(28)),
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback onTap;
  final BorderRadius borderRadius;
  final String? semanticLabel;

  @override
  State<GlassPress> createState() => _GlassPressState();
}

class _GlassPressState extends State<GlassPress> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      excludeSemantics: widget.semanticLabel != null,
      child: Material(
        color: Colors.transparent,
        borderRadius: widget.borderRadius,
        child: InkWell(
          borderRadius: widget.borderRadius,
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: widget.onTap,
          child: LiquidSquash(pressed: _down, child: widget.child),
        ),
      ),
    );
  }
}

/// Short squash while a control is held. It does not tick when idle.
class LiquidSquash extends StatelessWidget {
  const LiquidSquash({super.key, required this.pressed, required this.child});

  final bool pressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: pressed ? 1 : 0),
      duration: reduce ? Duration.zero : const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        return Transform(
          alignment: Alignment.center,
          filterQuality: FilterQuality.low,
          transform: Matrix4.diagonal3Values(1 + 0.045 * t, 1 - 0.06 * t, 1),
          child: child,
        );
      },
      child: child,
    );
  }
}

/// Filled-button layer. Buttons that set their own background color
/// (Delete, Disconnect, Cancel) keep that color.
Widget liquidGlassButtonLayer(BuildContext context, Set<WidgetState> states, Widget? child) {
  final button = context.widget;
  if (button is ButtonStyleButton && button.style?.backgroundColor != null) {
    return child ?? const SizedBox.shrink();
  }
  final dark = Theme.of(context).brightness == Brightness.dark;
  final pressed = states.contains(WidgetState.pressed);
  return LiquidSquash(
    pressed: pressed,
    child: CustomPaint(
      painter: IosGlassPainter(dark: dark),
      child: child,
    ),
  );
}

/// Traveling lens. It stretches only while the selection moves.
class LiquidSlider extends StatefulWidget {
  const LiquidSlider({
    super.key,
    required this.index,
    required this.count,
    required this.slotWidth,
    required this.dark,
    this.glass = true,
    this.flatColor,
    this.pad = 5,
    this.navKey = false,
    this.vertical = false,
  });

  final int index;
  final int count;
  final double slotWidth;
  final bool dark;
  final bool glass;
  final Color? flatColor;
  final double pad;
  final bool navKey;

  /// Travel along the column (desktop sidebar) instead of the row (tab bar).
  final bool vertical;

  @override
  State<LiquidSlider> createState() => _LiquidSliderState();
}

class _LiquidSliderState extends State<LiquidSlider> with SingleTickerProviderStateMixin {
  late final AnimationController _travel;
  late double _from;
  late double _to;

  @override
  void initState() {
    super.initState();
    _from = widget.index.toDouble();
    _to = _from;
    _travel = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  }

  @override
  void didUpdateWidget(covariant LiquidSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) _go(widget.index.toDouble());
  }

  @override
  void dispose() {
    _travel.dispose();
    super.dispose();
  }

  double _visualIndex() {
    final t = _travel.value.clamp(0.0, 1.0);
    return _from + (_to - _from) * Curves.easeInOutCubic.transform(t);
  }

  void _go(double target) {
    _from = _visualIndex();
    _to = target;
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce || (_from - _to).abs() < 0.001) {
      _from = target;
      _to = target;
      _travel.value = 1;
      return;
    }
    final slots = (_to - _from).abs();
    final ms = (380 + 40 * slots).round().clamp(380, 520);
    _travel.duration = Duration(milliseconds: ms);
    _travel.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final lens = IgnorePointer(
      key: widget.navKey ? const ValueKey('nav-active-oval') : null,
      child: widget.glass
          ? IosGlassPlate(dark: widget.dark, shadow: true, child: const SizedBox.expand())
          : DecoratedBox(
              decoration: ShapeDecoration(
                color: widget.flatColor ?? Colors.white.withValues(alpha: 0.16),
                shape: const StadiumBorder(),
              ),
              child: const SizedBox.expand(),
            ),
    );

    return AnimatedBuilder(
      animation: _travel,
      builder: (context, child) {
        final slot = widget.slotWidth;
        if (slot <= 0 || widget.count <= 0) return const SizedBox.shrink();
        final bar = slot * widget.count;
        final t = _travel.value.clamp(0.0, 1.0);
        final eased = Curves.easeInOutCubic.transform(t);
        final pos = _from + (_to - _from) * eased;
        final slots = (_to - _from).abs();
        final rest = math.max(slot - widget.pad * 2, 8.0);
        final bulge = math.sin(math.pi * t);
        final extra = bulge * slot * slots * 0.65;
        final width = math.min(rest + extra, math.max(rest, bar - 8));
        final dir = (_to - _from).sign;
        final center = slot * pos + slot / 2 + bulge * slot * 0.08 * dir;
        const minLeft = 4.0;
        final maxLeft = math.max(minLeft, bar - width - 4);
        final left = (center - width / 2).clamp(minLeft, maxLeft);
        final squeeze = bulge * 2.0;
        final cross = widget.pad + squeeze;
        if (widget.vertical) {
          return Positioned(
            top: left,
            height: width,
            left: cross,
            right: cross,
            child: child!,
          );
        }
        return Positioned(
          left: left,
          top: cross,
          bottom: cross,
          width: width,
          child: child!,
        );
      },
      child: lens,
    );
  }
}

/// Puts [child] in a stack and, when liquid glass is on, slides a lens
/// behind [count] equal slots. When it is off, [child] is returned as-is
/// so the existing per-tab fill stays.
class GlassChoiceShell extends StatelessWidget {
  const GlassChoiceShell({
    super.key,
    required this.index,
    required this.count,
    required this.child,
    this.pad = 0,
  });

  final int index;
  final int count;
  final Widget child;
  final double pad;

  @override
  Widget build(BuildContext context) {
    if (!LiquidGlassScope.of(context)) return child;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, box) {
        final slots = count <= 0 ? 1 : count;
        return Stack(
          alignment: Alignment.center,
          children: [
            LiquidSlider(
              index: index.clamp(0, slots - 1).toInt(),
              count: slots,
              slotWidth: box.maxWidth / slots,
              dark: dark,
              pad: pad,
            ),
            child,
          ],
        );
      },
    );
  }
}

enum ThemeModePlain { solid, segmented }

/// System / Light / Dark (or Auto / Light / Dark). The lens travels when
/// liquid glass is on. [plain] is the control used when it is off.
class ThemeModePicker extends StatelessWidget {
  const ThemeModePicker({
    super.key,
    required this.mode,
    required this.onChanged,
    this.systemLabel = 'System',
    this.systemIcon = Icons.devices,
    this.plain = ThemeModePlain.solid,
  });

  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;
  final String systemLabel;
  final IconData systemIcon;
  final ThemeModePlain plain;

  @override
  Widget build(BuildContext context) {
    if (!LiquidGlassScope.of(context)) {
      return plain == ThemeModePlain.segmented ? _segmented(context) : _solid(context);
    }
    final scheme = Theme.of(context).colorScheme;
    final items = <(ThemeMode, IconData, String)>[
      (ThemeMode.system, systemIcon, systemLabel),
      (ThemeMode.light, Icons.light_mode, 'Light'),
      (ThemeMode.dark, Icons.dark_mode_outlined, 'Dark'),
    ];
    final index = items.indexWhere((item) => item.$1 == mode);
    return Container(
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(999),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          return Stack(
            alignment: Alignment.center,
            children: [
              LiquidSlider(
                index: index < 0 ? 0 : index,
                count: items.length,
                slotWidth: box.maxWidth / items.length,
                dark: scheme.brightness == Brightness.dark,
                pad: 0,
              ),
              Row(
                children: [
                  for (final item in items)
                    Expanded(child: _glassCell(context, item.$1, item.$2, item.$3)),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _glassCell(BuildContext context, ThemeMode value, IconData icon, String label) {
    final scheme = Theme.of(context).colorScheme;
    final selected = mode == value;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(value),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _solid(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget cell(String label, IconData icon, ThemeMode value) {
      final selected = mode == value;
      return Expanded(
        child: Material(
          color: selected ? scheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            onTap: () => onChanged(value),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 16, color: selected ? scheme.onPrimary : scheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          cell(systemLabel, systemIcon, ThemeMode.system),
          cell('Light', Icons.light_mode, ThemeMode.light),
          cell('Dark', Icons.dark_mode_outlined, ThemeMode.dark),
        ],
      ),
    );
  }

  Widget _segmented(BuildContext context) {
    return SegmentedButton<ThemeMode>(
      segments: [
        ButtonSegment(value: ThemeMode.system, label: Text(systemLabel), icon: Icon(systemIcon)),
        const ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_rounded)),
        const ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_rounded)),
      ],
      selected: {mode},
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}

/// Segmented control that uses the traveling lens when liquid glass is on,
/// and the normal [SegmentedButton] when it is off.
class LiquidOrSegmented<T> extends StatelessWidget {
  const LiquidOrSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onSelectionChanged,
    this.showSelectedIcon = false,
    this.enabled = true,
  });

  final List<ButtonSegment<T>> segments;
  final T selected;
  final ValueChanged<Set<T>>? onSelectionChanged;
  final bool showSelectedIcon;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!LiquidGlassScope.of(context) || segments.isEmpty) {
      return SegmentedButton<T>(
        showSelectedIcon: showSelectedIcon,
        segments: segments,
        selected: {selected},
        onSelectionChanged: enabled ? onSelectionChanged : null,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final index = segments.indexWhere((segment) => segment.value == selected);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.45)),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          return Stack(
            alignment: Alignment.center,
            children: [
              LiquidSlider(
                index: index < 0 ? 0 : index,
                count: segments.length,
                slotWidth: box.maxWidth / segments.length,
                dark: scheme.brightness == Brightness.dark,
                pad: 0,
              ),
              Row(
                children: [
                  for (final segment in segments)
                    Expanded(child: _cell(context, segment)),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _cell(BuildContext context, ButtonSegment<T> segment) {
    final scheme = Theme.of(context).colorScheme;
    final on = segment.value == selected;
    final color = on ? scheme.primary : scheme.onSurfaceVariant;
    final canTap = enabled && segment.enabled && onSelectionChanged != null;
    final body = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (segment.icon != null) ...[
            IconTheme.merge(
              data: IconThemeData(size: 18, color: color),
              child: segment.icon!,
            ),
            if (segment.label != null) const SizedBox(width: 4),
          ],
          if (segment.label != null)
            Flexible(
              child: DefaultTextStyle.merge(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
                child: segment.label!,
              ),
            ),
        ],
      ),
    );
    return Semantics(
      button: true,
      selected: on,
      enabled: canTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: canTap ? () => onSelectionChanged!({segment.value}) : null,
        child: segment.tooltip == null ? body : Tooltip(message: segment.tooltip, child: body),
      ),
    );
  }
}
