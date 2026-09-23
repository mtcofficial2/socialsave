import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/shared/models/media_format.dart';

class QualitySelector extends ConsumerWidget {
  const QualitySelector({
    super.key,
    required this.formats,
    required this.selected,
    required this.onSelected,
  });

  final List<MediaFormat> formats;
  final MediaFormat? selected;
  final ValueChanged<MediaFormat> onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (formats.isEmpty) {
      return const Text('No downloadable formats were returned for this URL.');
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: formats.map((format) {
        final isSelected = selected?.id == format.id;
        return _SelectablePill(
          label: _chipLabel(format),
          selected: isSelected,
          onTap: () => onSelected(format),
        );
      }).toList(),
    );
  }

  String _chipLabel(MediaFormat format) {
    final quality = format.quality.toLowerCase();
    if (quality == 'original' || quality == 'best') return 'Best';
    if (quality == 'auto') return 'Auto';
    return format.quality;
  }
}

class FormatSelector extends StatelessWidget {
  const FormatSelector({
    super.key,
    required this.formats,
    required this.selected,
    required this.onSelected,
  });

  final List<String> formats;
  final String? selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: formats.map((format) {
        return _SelectablePill(
          label: format.toUpperCase(),
          selected: selected?.toLowerCase() == format.toLowerCase(),
          onTap: () => onSelected(format),
        );
      }).toList(),
    );
  }
}

class _SelectablePill extends StatelessWidget {
  const _SelectablePill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? Color.alphaBlend(
              scheme.primary.withValues(alpha: 0.12),
              scheme.surfaceContainerLowest,
            )
          : scheme.surfaceContainerLowest,
      shape: StadiumBorder(
        side: BorderSide(color: selected ? scheme.primary : scheme.outline),
      ),
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
              color: selected ? scheme.primary : scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}
