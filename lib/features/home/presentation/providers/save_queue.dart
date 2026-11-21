import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/errors/error_messages.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/core/utils/together.dart';
import 'package:social_save/core/utils/video_links.dart';
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
  var _active = 0;

  @override
  List<SaveQueueItem> build() => const [];

  void add(String url) => addAll([url]);

  /// Queues every video link in [raw] when there are at least two.
  /// Returns how many were queued. One link stays on the single-link path.
  int addBrought(String? raw) {
    final links = linksToSaveTogether(raw);
    if (links.isEmpty) return 0;
    addAll(links);
    return links.length;
  }

  void addAll(Iterable<String> urls) {
    final seen = {
      for (final item in state)
        if (item.phase == SavePhase.waiting || item.phase == SavePhase.saving) item.url,
    };
    final next = [...state];
    var added = false;
    for (final raw in urls) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) continue;
      next.add(SaveQueueItem(
        id: _uuid.v4(),
        url: trimmed,
        title: trimmed,
        phase: SavePhase.waiting,
      ));
      added = true;
    }
    if (!added) return;
    state = next;
    _pump();
  }

  /// Looks up several waiting links at once. A download keeps going after
  /// it is queued, so the next link does not wait for that file to finish.
  void _pump() {
    while (_active < saveAtOnce) {
      final index = state.indexWhere((item) => item.phase == SavePhase.waiting);
      if (index < 0) return;
      final current = state[index];
      _replace(current.copyWith(phase: SavePhase.saving, title: 'Looking up…'));
      _active++;
      unawaited(_one(current));
    }
  }

  Future<void> _one(SaveQueueItem current) async {
    try {
      final media = await ref.read(mediaRepositoryProvider).analyze(current.url);
      final format = _formatFor(media);
      if (format == null) {
        _replace(current.copyWith(
          title: media.title,
          phase: SavePhase.failed,
          detail: 'No downloadable quality was found.',
        ));
        return;
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
      if (error.message == ErrorMessages.alreadySaved) {
        _replace(current.copyWith(
          title: current.title,
          phase: SavePhase.done,
          detail: 'Already on this device',
        ));
        return;
      }
      _replace(current.copyWith(
        phase: SavePhase.failed,
        detail: error.message,
      ));
    } catch (_) {
      _replace(current.copyWith(
        phase: SavePhase.failed,
        detail: 'Could not add this link.',
      ));
    } finally {
      _active--;
      _pump();
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
