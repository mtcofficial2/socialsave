import 'package:flutter/material.dart';

/// A softly pulsing placeholder block used while content loads.
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({super.key, this.height, this.width, this.radius = 12});

  final double? height;
  final double? width;
  final double radius;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        height: widget.height,
        width: widget.width,
        decoration: BoxDecoration(
          color: Color.lerp(scheme.surfaceContainer, scheme.surfaceContainerHighest, _c.value),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      ),
    );
  }
}

/// Grid of thumbnail placeholders (Library).
class SkeletonGrid extends StatelessWidget {
  const SkeletonGrid({super.key, this.count = 8});

  final int count;

  @override
  Widget build(BuildContext context) {
    final gutter = MediaQuery.sizeOf(context).width >= 840 ? 24.0 : 16.0;
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 240,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: count,
      itemBuilder: (context, _) => const SkeletonBox(radius: 16),
    );
  }
}

/// List row placeholders (Downloads, Received).
class SkeletonList extends StatelessWidget {
  const SkeletonList({
    super.key,
    this.count = 6,
    this.padding,
    this.leadingSize = 72,
    this.leadingRadius = 12,
  });

  final int count;
  final EdgeInsets? padding;

  /// Size of the leading block: 72 for thumbnails, about 52 for avatars.
  final double leadingSize;

  /// Corner of the leading block. Half of [leadingSize] draws a circle.
  final double leadingRadius;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading',
      child: ExcludeSemantics(
        child: ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      padding: padding ?? const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: count,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, _) => Row(
        children: [
          SkeletonBox(width: leadingSize, height: leadingSize, radius: leadingRadius),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(height: 14, radius: 6),
                SizedBox(height: 8),
                SkeletonBox(height: 12, width: 140, radius: 6),
              ],
            ),
          ),
        ],
      ),
        ),
      ),
    );
  }
}
