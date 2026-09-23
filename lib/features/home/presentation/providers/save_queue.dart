import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/features/downloader/presentation/providers/download_manager.dart';
import 'package:social_save/features/settings/domain/entities/app_settings.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';
import 'package:social_save/shared/models/media_format.dart';
import 'package:social_save/shared/models/media_info.dart';
import 'package:uuid/uuid.dart';

enum SavePhase { waiting, saving, done, failed }

class SaveQueueItem {
  const SaveQueueItem({
    required this.id,
    required this.url,
    required this.title,
    required this.phase,
    this.detail,
  });

  final String id;
  final String url;
  final String title;
  final SavePhase phase;
  final String? detail;

  SaveQueueItem copyWith({String? title, SavePhase? phase, String? detail}) {
    return SaveQueueItem(
      id: id,
      url: url,
      title: title ?? this.title,
      phase: phase ?? this.phase,
      detail: detail ?? this.detail,
    );
  }
}

final saveQueueProvider =
    NotifierProvider<SaveQueueController, List<SaveQueueItem>>(SaveQueueController.new);

class SaveQueueController extends Notifier<List<SaveQueueItem>> {
  final _uuid = const Uuid();
  var _busy = false;

  @override
  List<SaveQueueItem> build() => const [];

  void add(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return;
    state = [
      ...state,
      SaveQueueItem(
        id: _uuid.v4(),
        url: trimmed,
        title: trimmed,
        phase: SavePhase.waiting,
      ),
    ];
    _pump();
  }

  Future<void> _pump() async {
    if (_busy) return;
    _busy = true;
    try {
      while (true) {
        final index = state.indexWhere((item) => item.phase == SavePhase.waiting);
        if (index < 0) break;
        final current = state[index];
        _replace(current.copyWith(phase: SavePhase.saving, title: 'Looking up…'));
        try {
          final media = await ref.read(mediaRepositoryProvider).analyze(current.url);
          final format = _formatFor(media);
          if (format == null) {
            _replace(current.copyWith(
              title: media.title,
              phase: SavePhase.failed,
              detail: 'No downloadable quality was found.',
            ));
            continue;
          }
          await ref.read(downloadManagerProvider.notifier).enqueue(
                media: media,
                format: format,
              );
          _replace(current.copyWith(
            title: media.title,
            phase: SavePhase.done,
            detail: 'Saving in Downloads',
          ));
        } on AppException catch (error) {
          _replace(current.copyWith(
            phase: SavePhase.failed,
            detail: error.message,
          ));
        } catch (_) {
          _replace(current.copyWith(
            phase: SavePhase.failed,
            detail: 'Could not add this link.',
          ));
        }
      }
    } finally {
      _busy = false;
    }
  }

  void _replace(SaveQueueItem item) {
    state = [
      for (final current in state)
        if (current.id == item.id) item else current,
    ];
  }

  MediaFormat? _formatFor(MediaInfo media) {
    if (media.formats.isEmpty) return null;
    final settings = ref.read(settingsControllerProvider);
    final wanted = (settings.lastChosenQuality ?? settings.defaultQuality.apiValue).toLowerCase();
    for (final item in media.formats) {
      if (item.quality.toLowerCase() == wanted) return item;
    }
    return media.defaultFormat ?? media.formats.first;
  }
}
