import 'package:flutter/material.dart';
import 'package:social_save/core/engine/local_engine.dart';
import 'package:social_save/shared/widgets/glass.dart';

/// Desktop: the bundled download engine (status, yt-dlp version, update).
class EngineSection extends StatelessWidget {
  const EngineSection({super.key, required this.title});

  /// The settings screen's group title widget.
  final Widget title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        title,
        GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ValueListenableBuilder<EngineStatus>(
              valueListenable: LocalEngine.status,
              builder: (context, s, _) {
                final (label, color) = switch (s.state) {
                  'ready' => ('Ready on this PC', scheme.primary),
                  'starting' => ('Starting…', scheme.onSurfaceVariant),
                  _ => ('Not running', scheme.error),
                };
                return Column(
                  key: const ValueKey('engine-section'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.memory_rounded, color: color),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Download engine: $label',
                                  style: const TextStyle(fontWeight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text(
                                'Links are analyzed and saved on this PC with yt-dlp'
                                '${s.hasFfmpeg ? ' and ffmpeg' : ''}. No SocialSave server is used.',
                                style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (s.message.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(s.message, style: TextStyle(color: scheme.error, fontSize: 12.5)),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _chip(context, 'yt-dlp ${s.ytdlp.isEmpty ? '—' : s.ytdlp}'),
                        _chip(context, s.hasFfmpeg ? 'ffmpeg: merges HD video + audio' : 'ffmpeg missing'),
                        _chip(context, s.hasDeno ? 'YouTube solver: deno' : 'YouTube solver missing'),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        FilledButton.tonalIcon(
                          key: const ValueKey('engine-update'),
                          onPressed: s.updating
                              ? null
                              : () async {
                                  final messenger = ScaffoldMessenger.of(context);
                                  final changed = await LocalEngine.updateYtdlp(restartAfter: true);
                                  messenger.showSnackBar(SnackBar(
                                    content: Text(changed
                                        ? 'yt-dlp updated to ${LocalEngine.status.value.ytdlp}.'
                                        : 'yt-dlp is up to date.'),
                                  ));
                                },
                          icon: s.updating
                              ? const SizedBox(
                                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.system_update_alt_rounded),
                          label: Text(s.updating ? 'Checking…' : 'Check for yt-dlp update'),
                        ),
                        const SizedBox(width: 8),
                        if (!s.ready)
                          TextButton(
                            onPressed: () => LocalEngine.restart(),
                            child: const Text('Restart engine'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'yt-dlp is checked for updates once a day.',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _chip(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
    );
  }
}
