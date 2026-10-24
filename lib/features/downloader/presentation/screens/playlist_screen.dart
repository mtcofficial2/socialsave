import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/core/utils/set_link.dart';
import 'package:social_save/features/downloader/follow_creator.dart';
import 'package:social_save/features/downloader/presentation/providers/download_manager.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';
import 'package:social_save/shared/models/media_format.dart';
import 'package:social_save/shared/models/playlist_entry.dart';
import 'package:social_save/shared/widgets/empty_state.dart';
import 'package:social_save/shared/widgets/page_layout.dart';

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
  int _step = 0;
  int _saveTotal = 0;
  bool _following = false;

  @override
  void initState() {
    super.initState();
    _load();
    unawaited(_loadFollow());
  }

  Future<void> _loadFollow() async {
    final on = await FollowCreator.isFollowing(widget.url);
    if (mounted) setState(() => _following = on);
  }

  Future<void> _load() async {
    try {
      final raw = await ref.read(mediaRepositoryProvider).playlist(widget.url);
      final items = await expandChannelSections(
        raw,
        (url) => ref.read(mediaRepositoryProvider).playlist(url),
      );
      if (!mounted) return;
      final onlyTabs = raw.isNotEmpty &&
          raw.every((entry) => isChannelSection(entry.url) || youtubeChannelRoot(entry.url) != null);
      if (items.isEmpty && onlyTabs) {
        setState(() {
          _error = 'This page listed channel tabs, not videos. Try again in a moment.';
          _loading = false;
        });
        return;
      }
      setState(() {
        _items = items;
        _selected
          ..clear()
          ..addAll(List.generate(items.length, (index) => index));
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
        _error = 'Could not read this public set.';
        _loading = false;
      });
    }
  }

  bool _isTab(String url) => isChannelSection(url) || youtubeChannelRoot(url) != null;

  Future<void> _saveSelected() async {
    final indexes = _selected.toList()..sort();
    final targets = <PlaylistEntry>[];
    for (final index in indexes) {
      if (index < 0 || index >= _items.length) continue;
      final entry = _items[index];
      if (_isTab(entry.url)) continue;
      targets.add(entry);
    }
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('These rows are channel tabs, not videos.')),
      );
      return;
    }
    setState(() {
      _saving = true;
      _step = 0;
      _saveTotal = targets.length;
    });
    var saved = 0;
    var skipped = 0;
    try {
      for (var i = 0; i < targets.length; i++) {
        if (!mounted) return;
        setState(() => _step = i + 1);
        final entry = targets[i];
        try {
          final media = await ref
              .read(mediaRepositoryProvider)
              .analyze(entry.url)
              .timeout(const Duration(seconds: 60));
          if (!mounted) return;
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
          await ref.read(downloadManagerProvider.notifier).enqueue(
                media: media,
                format: format,
                askExport: false,
              );
          saved++;
        } on AppException {
          skipped++;
        } on TimeoutException {
          skipped++;
        } catch (_) {
          skipped++;
        }
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Queued $saved. Skipped $skipped.')),
    );
  }

  Future<void> _toggleFollow() async {
    if (_following) {
      await FollowCreator.unfollow(widget.url);
      if (!mounted) return;
      setState(() => _following = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Overnight checks stopped for this set.')),
      );
      return;
    }
    await FollowCreator.follow(
      widget.url,
      _items.isEmpty ? 'Set' : _items.first.title,
      [for (final item in _items) item.url],
    );
    if (!mounted) return;
    setState(() => _following = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('New public posts from this set will be queued overnight. The posts already listed stay as they are.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Save this set')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? EmptyState(
                  icon: Icons.playlist_remove_rounded,
                  title: 'Could not open this set',
                  message: _error!,
                  action: FilledButton.icon(
                    onPressed: () {
                      setState(() {
                        _loading = true;
                        _error = null;
                      });
                      _load();
                    },
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Try again'),
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: pagePadding(context, top: 8, bottom: 8),
                      child: Text(
                        'Choose public videos to save. Private and login-only items are skipped.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: pagePadding(context, top: 0, bottom: 8),
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
                        // The home gesture band sits above the system inset on this phone.
                        padding: pagePadding(
                          context,
                          top: 8,
                          bottom: 12 + (MediaQuery.sizeOf(context).width < kDesktopShellMinWidth ? 56 : 0),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            FilledButton(
                              onPressed: _saving || _selected.isEmpty ? null : _saveSelected,
                              child: Text(
                                _saving ? 'Saving $_step of $_saveTotal' : 'Save this set (${_selected.length})',
                              ),
                            ),
                            if (canFollowSet(widget.url)) ...[
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                onPressed: _toggleFollow,
                                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                                icon: const Icon(Icons.nightlight_outlined),
                                label: Text(_following ? 'Stop overnight checks' : 'Check for new posts overnight'),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _following
                                    ? 'New public posts from this set are queued overnight.'
                                    : 'Posts already listed stay as they are. Nothing downloads until a new one appears.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.35,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
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
