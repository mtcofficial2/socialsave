import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:social_save/features/home/presentation/providers/home_controller.dart';
import 'package:social_save/features/library/bundle_transfer.dart' show isVideoName;
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/routing/app_router.dart';

/// Windows: drag files onto the SocialSave window.
///
/// * Video or audio files play in the player (several form a queue).
/// * An Internet shortcut (.url, e.g. dragged from a browser's address bar to
///   the desktop) or a .txt with a link opens it in Preview to download.
class WindowsDropZone extends ConsumerStatefulWidget {
  const WindowsDropZone({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<WindowsDropZone> createState() => _WindowsDropZoneState();
}

class _WindowsDropZoneState extends ConsumerState<WindowsDropZone> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) => setState(() => _hover = true),
      onDragExited: (_) => setState(() => _hover = false),
      onDragDone: (details) {
        setState(() => _hover = false);
        _handle([for (final f in details.files) f.path]);
      },
      child: Stack(
        children: [
          widget.child,
          if (_hover)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: scheme.primary, width: 2),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.file_download_rounded, size: 56, color: scheme.onPrimaryContainer),
                        const SizedBox(height: 12),
                        Text(
                          'Drop to open in SocialSave',
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                color: scheme.onPrimaryContainer,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Videos play here. A link shortcut (.url) opens it to download.',
                          style: TextStyle(color: scheme.onPrimaryContainer),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _handle(List<String> paths) async {
    final videos = <String>[];
    String? link;
    for (final path in paths) {
      if (path.isEmpty) continue;
      if (isVideoName(path)) {
        videos.add(path);
        continue;
      }
      final ext = p.extension(path).toLowerCase();
      if (link == null && (ext == '.url' || ext == '.txt' || ext == '.webloc')) {
        link = await _linkIn(File(path));
      }
    }
    if (!mounted) return;
    if (videos.isNotEmpty) {
      final queue = [
        for (final v in videos) PlayerQueueItem(title: p.basenameWithoutExtension(v), filePath: v),
      ];
      await appRouter.push(
        '/player',
        extra: PlayerSession(
          title: queue.first.title,
          platform: SocialPlatform.direct,
          filePath: videos.first,
          queue: queue,
        ),
      );
      return;
    }
    if (link != null) {
      final controller = ref.read(homeControllerProvider.notifier)..setUrl(link);
      final url = controller.validatedUrl();
      if (url != null) {
        appRouter.go('/');
        await appRouter.push('/preview', extra: url);
        return;
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Drop a video file, or a link shortcut (.url) to download it.')),
    );
  }

  /// First http(s) link inside a small text-like file.
  static Future<String?> _linkIn(File file) async {
    try {
      if (await file.length() > 64 * 1024) return null;
      final text = await file.readAsString();
      return RegExp(r'https?://[^\s"<>]+').firstMatch(text)?.group(0);
    } catch (_) {
      return null;
    }
  }
}
