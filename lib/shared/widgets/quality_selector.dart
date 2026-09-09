import 'package:flutter/material.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/shared/models/media_format.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    final formatters = ref.watch(formattersProvider);
    if (formats.isEmpty) {
      return const Text('No downloadable formats were returned for this URL.');
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: formats.map((format) {
        final isSelected = selected?.id == format.id;
        final size = format.filesize == null
            ? format.label
            : '${format.label} · ${formatters.bytes(format.filesize)}';
        return ChoiceChip(
          label: Text(size),
          selected: isSelected,
          onSelected: (_) => onSelected(format),
        );
      }).toList(),
    );
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
        return ChoiceChip(
          label: Text(format.toUpperCase()),
          selected: selected?.toLowerCase() == format.toLowerCase(),
          onSelected: (_) => onSelected(format),
        );
      }).toList(),
    );
  }
}
