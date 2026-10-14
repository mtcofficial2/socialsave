import 'package:flutter/material.dart';

/// Lays sections in two columns when there is room, otherwise stacks them.
class DesktopColumns extends StatelessWidget {
  const DesktopColumns({
    super.key,
    required this.sections,
    this.minWidth = 880,
    this.gap = 20,
  });

  final List<Widget> sections;
  final double minWidth;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width < minWidth) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final section in sections) ...[
                section,
                SizedBox(height: gap),
              ],
            ],
          );
        }
        final column = (width - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final section in sections) SizedBox(width: column, child: section),
          ],
        );
      },
    );
  }
}
