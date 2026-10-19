import 'dart:async';

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Subtitle look, remembered between videos.
class SubtitlePrefs {
  static const _sizeKey = 'socialsave_sub_size';
  static const _bgKey = 'socialsave_sub_bg';
  static final ValueNotifier<double> size = ValueNotifier(36);
  static final ValueNotifier<bool> background = ValueNotifier(true);
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final p = await SharedPreferences.getInstance();
    size.value = p.getDouble(_sizeKey) ?? 36;
    background.value = p.getBool(_bgKey) ?? true;
  }

  static Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_sizeKey, size.value);
    await p.setBool(_bgKey, background.value);
  }

  static SubtitleViewConfiguration config() => SubtitleViewConfiguration(
        style: TextStyle(
          height: 1.3,
          fontSize: size.value,
          color: Colors.white,
          fontWeight: FontWeight.w600,
          backgroundColor: background.value ? const Color(0xAA000000) : null,
        ),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 56),
      );
}

/// Subtitle size, background and "load a subtitle file" for the tools sheet.
class SubtitleToolsRow extends StatelessWidget {
  const SubtitleToolsRow({super.key, required this.player, required this.onChanged});
  final Player player;
  final VoidCallback onChanged;

  Future<void> _load(BuildContext context) async {
    final file = await fs.openFile(acceptedTypeGroups: const [
      fs.XTypeGroup(label: 'Subtitles', extensions: ['srt', 'vtt', 'ass', 'ssa', 'sub']),
    ]);
    if (file == null) return;
    try {
      await player.setSubtitleTrack(SubtitleTrack.uri(Uri.file(file.path).toString(), title: file.name));
      HapticFeedback.selectionClick();
      onChanged();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('That subtitle file could not be loaded.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            Text('Captions', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _load(context),
              icon: const Icon(Icons.subtitles_rounded, size: 18),
              label: const Text('Load subtitle file'),
            ),
          ],
        ),
        ValueListenableBuilder<double>(
          valueListenable: SubtitlePrefs.size,
          builder: (context, v, _) => Row(
            children: [
              Icon(Icons.format_size_rounded, color: cs.onSurfaceVariant),
              Expanded(
                child: Semantics(
                  label: 'Subtitle size',
                  child: Slider(
                    min: 18,
                    max: 64,
                    value: v.clamp(18, 64),
                    onChanged: (x) {
                      SubtitlePrefs.size.value = x;
                      onChanged();
                    },
                    onChangeEnd: (_) => SubtitlePrefs.save(),
                  ),
                ),
              ),
            ],
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: SubtitlePrefs.background,
          builder: (context, v, _) => SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('Dark box behind captions', style: TextStyle(color: cs.onSurface)),
            value: v,
            onChanged: (x) {
              SubtitlePrefs.background.value = x;
              SubtitlePrefs.save();
              onChanged();
            },
          ),
        ),
      ],
    );
  }
}