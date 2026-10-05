import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/features/downloader/presentation/providers/download_manager.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';
import 'package:social_save/shared/models/media_format.dart';
import 'package:social_save/shared/models/playlist_entry.dart';

class PlaylistScreen extends ConsumerStatefulWidget {
  const PlaylistScreen({super.key, required this.url});

  final String url;

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen> {
  bool _loading = true;
  String? _error;
  List<PlaylistEntry> _items = const [];
  final Set<int> _selected = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await ref.read(mediaRepositoryProvider).playlist(widget.url);
      if (!mounted) return;
      setState(() {
        _items = items;
        _selected.addAll(List.generate(items.length, (index) => index));
        _loading = false;
      });
    } on AppException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not read this public playlist.';
        _loading = false;
      });
    }
  }

  Future<void> _saveSelected() async {
    setState(() => _saving = true);
    var saved = 0;
    var skipped = 0;
    for (final index in _selected) {
      final entry = _items[index];
      try {
        final media = await ref.read(mediaRepositoryProvider).analyze(entry.url);
        if (!media.canDownload) {
          skipped++;
          continue;
        }
        final settings = ref.read(settingsControllerProvider);
        final remembered = settings.qualityByPlatform[media.platform.id];
        MediaFormat? format;
        for (final item in media.formats) {
          if (remembered != null && item.quality.toLowerCase() == remembered.toLowerCase()) {
            format = item;
            break;
          }
        }
        format ??= _firstQuality(media.formats, 'auto') ?? media.defaultFormat;
        if (format == null) {
          skipped++;
          continue;
        }
        await ref.read(downloadManagerProvider.notifier).enqueue(media: media, format: format);
        saved++;
      } on AppException catch (error) {
        if (error.message.toLowerCase().contains('already saved')) {
          skipped++;
        } else {
          skipped++;
        }
      } catch (_) {
        skipped++;
      }
    }
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Queued $saved. Skipped $skipped.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Public playlist')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Text(
                        'Choose public videos to save. Private and login-only items are skipped.',
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _items.length,
                        itemBuilder: (context, index) {
                          final item = _items[index];
                          final seconds = item.durationSeconds;
                          return CheckboxListTile(
                            value: _selected.contains(index),
                            onChanged: _saving
                                ? null
                                : (value) {
                                    setState(() {
                                      if (value == true) {
                                        _selected.add(index);
                                      } else {
                                        _selected.remove(index);
                                      }
                                    });
                                  },
                            title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: Text(seconds == null ? item.url : '${seconds}s'),
                          );
                        },
                      ),
                    ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: FilledButton(
                          onPressed: _saving || _selected.isEmpty ? null : _saveSelected,
                          child: Text(_saving ? 'Saving…' : 'Save selected'),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

MediaFormat? _firstQuality(List<MediaFormat> formats, String quality) {
  for (final item in formats) {
    if (item.quality.toLowerCase() == quality) return item;
  }
  return null;
}
