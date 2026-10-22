import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/shared/widgets/liquid_glass.dart';
import 'package:social_save/features/library/device_media.dart';
import 'package:social_save/features/library/transfer_meter.dart';

/// What the session picker can list.
enum MediaKind { video, image, audio }

/// One item in the session media picker.
class MediaEntry {
  MediaEntry({
    required this.key,
    required this.kind,
    required this.name,
    this.id,
    this.uri,
    this.path,
    this.size = 0,
    this.durationMs = 0,
    this.addedAt = 0,
    this.bucket = '',
  }) : lower = name.toLowerCase();

  final String key;
  final MediaKind kind;
  final String name;
  final String lower;
  final String? id;
  final String? uri;
  final String? path;
  final int size;
  final int durationMs;

  /// Seconds since epoch.
  final int addedAt;

  /// Folder name (MediaStore bucket on Android, parent folder on Windows).
  final String bucket;

  String get _p => (path ?? '').replaceAll('\\', '/').toLowerCase();
  bool get isSocialSave => _p.contains('/socialsave/') || bucket.toLowerCase() == 'socialsave';
  bool get isCamera => _p.contains('/dcim/') || bucket.toLowerCase() == 'camera';
  bool get isDownload => _p.contains('/download/') || _p.contains('/downloads/') || bucket.toLowerCase() == 'download';
  bool get isWhatsApp => _p.contains('whatsapp') || bucket.toLowerCase().contains('whatsapp');
}

/// Loads device media for the picker: MediaStore pages on Android, the
/// Library's folder scan on Windows. Thumbnails are cached on disk by the
/// platform side and their paths in memory here.
class MediaCatalog {
  MediaCatalog._();

  static const _channel = MethodChannel('socialsave/media');
  static const int pageSize = 300;

  /// Thumbnail path futures, most recent last (bounded).
  static final LinkedHashMap<String, Future<String?>> _thumbs = LinkedHashMap();

  static Future<String?> thumbnail(MediaEntry e) {
    final hit = _thumbs.remove(e.key);
    if (hit != null) {
      _thumbs[e.key] = hit;
      return hit;
    }
    final Future<String?> f;
    if (Plat.isWindows) {
      f = e.path == null ? Future.value(null) : DeviceMediaService().videoThumbnail(path: e.path);
    } else {
      // Unique cache id per collection, so a photo and a video with the same
      // MediaStore id never share a thumbnail.
      f = DeviceMediaService().videoThumbnail(id: 'pick_${e.kind.name}_${e.id}', path: e.path, uri: e.uri);
    }
    _thumbs[e.key] = f;
    while (_thumbs.length > 3000) {
      _thumbs.remove(_thumbs.keys.first);
    }
    return f;
  }

  /// Streams the growing list (newest first) as pages arrive.
  static Stream<List<MediaEntry>> load(MediaKind kind) async* {
    if (Plat.isWindows) {
      if (kind != MediaKind.video) {
        yield const [];
        return;
      }
      final svc = DeviceMediaService();
      final cached = svc.cachedWindows;
      if (cached != null) yield _sortW(cached);
      await for (final list in svc.scanWindows()) {
        yield _sortW(list);
      }
      return;
    }
    final all = <MediaEntry>[];
    var offset = 0;
    while (true) {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('queryMedia', {
        'kind': kind.name,
        'offset': offset,
        'limit': pageSize,
      });
      final items = (raw?['items'] as List?) ?? const [];
      final total = (raw?['total'] as num?)?.toInt() ?? 0;
      for (final it in items.whereType<Map<Object?, Object?>>()) {
        final id = '${it['id']}';
        final path = it['path'] as String?;
        if (path != null && (path.contains('/vault/') || path.contains('/files/vault'))) continue;
        all.add(MediaEntry(
          key: '${kind.name}:$id',
          kind: kind,
          id: id,
          uri: it['uri'] as String?,
          path: path,
          name: (it['name'] as String?)?.trim().isNotEmpty == true ? it['name'] as String : p.basename(path ?? 'file'),
          size: (it['size'] as num?)?.toInt() ?? 0,
          durationMs: (it['durationMs'] as num?)?.toInt() ?? 0,
          addedAt: (it['addedAt'] as num?)?.toInt() ?? 0,
          bucket: (it['bucket'] as String?) ?? _bucketOf(it['relativePath'] as String?, path),
        ));
      }
      yield List.unmodifiable(all);
      offset += items.length;
      if (items.isEmpty || offset >= total) break;
    }
  }

  static String _bucketOf(String? rel, String? path) {
    final src = (rel ?? (path == null ? '' : p.dirname(path))).replaceAll('\\', '/');
    final parts = src.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? '' : parts.last;
  }

  static List<MediaEntry> _sortW(List<DeviceVideo> list) {
    final out = [
      for (final v in list)
        if (v.path != null)
          MediaEntry(
            key: 'w:${v.path!.toLowerCase()}',
            kind: MediaKind.video,
            id: v.id,
            path: v.path,
            name: p.basename(v.path!),
            size: v.size,
            durationMs: v.durationMs,
            addedAt: v.addedAt > 100000000000 ? v.addedAt ~/ 1000 : v.addedAt,
            bucket: p.basename(v.folder ?? p.dirname(v.path!)),
          ),
    ]..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return out;
  }

  /// Asks for read access to [kind]. Returns 'granted', 'limited' or 'denied'.
  static Future<String> ensureAccess(MediaKind kind) async {
    if (!Plat.isAndroid) return 'granted';
    final perm = switch (kind) {
      MediaKind.video => Permission.videos,
      MediaKind.image => Permission.photos,
      MediaKind.audio => Permission.audio,
    };
    final a = await perm.request();
    if (a.isGranted) return 'granted';
    // Android 12 and older use the storage permission instead.
    final s = await Permission.storage.request();
    if (s.isGranted) return 'granted';
    if (a.isLimited || s.isLimited) return 'limited';
    return 'denied';
  }

  /// A real file for [e], copying from MediaStore when the path is not readable.
  static Future<File?> fileFor(MediaEntry e) async {
    final path = e.path;
    if (path != null && path.isNotEmpty) {
      final f = File(path);
      try {
        if (f.existsSync() && f.lengthSync() >= 0) {
          await f.openRead(0, 1).drain<void>();
          return f;
        }
      } catch (_) {}
    }
    if (!Plat.isAndroid) return null;
    final copied = await DeviceMediaService().resolvePlayablePath(
      DeviceVideo(id: e.kind == MediaKind.video ? e.id ?? '' : '', title: e.name, path: e.path, uri: e.uri),
    );
    if (copied == null) return null;
    // The copy has a generic name; give it the real one so the receiver sees it.
    try {
      final dir = Directory(p.join((await getTemporaryDirectory()).path, 'session_send'));
      await dir.create(recursive: true);
      final named = File(p.join(dir.path, e.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')));
      if (named.existsSync()) await named.delete();
      return await File(copied).rename(named.path);
    } catch (_) {
      return File(copied);
    }
  }
}

String _duration(int ms) {
  if (ms <= 0) return '';
  final s = ms ~/ 1000;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

/// Xender-style picker: every video on the device in a grid, with search,
/// folder chips and multi-select. [onSend] gets the chosen files.
class SessionMediaPicker extends StatefulWidget {
  const SessionMediaPicker({super.key, required this.onSend, required this.onBrowseFiles, this.enabled = true});

  final Future<void> Function(List<MediaEntry> picked) onSend;
  final VoidCallback onBrowseFiles;
  final bool enabled;

  @override
  State<SessionMediaPicker> createState() => _SessionMediaPickerState();
}

/// Test hook (--picker-test): select this many items once the list loads.
int debugPickerAutoSelect = 0;

class _SessionMediaPickerState extends State<SessionMediaPicker> with AutomaticKeepAliveClientMixin {
  MediaKind _kind = MediaKind.video;
  String _filter = 'all'; // all, socialsave, camera, downloads, whatsapp, folder
  String? _folder;
  String _query = '';
  final _search = TextEditingController();
  final Map<MediaKind, List<MediaEntry>> _lists = {};
  final Map<MediaKind, bool> _loading = {};
  final Map<MediaKind, String> _access = {};
  final Map<String, MediaEntry> _selected = {};
  final Map<MediaKind, StreamSubscription<List<MediaEntry>>> _subs = {};
  bool _sending = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_load(MediaKind.video));
  }

  @override
  void dispose() {
    for (final s in _subs.values) {
      s.cancel();
    }
    _search.dispose();
    super.dispose();
  }

  Future<void> _load(MediaKind kind, {bool force = false}) async {
    if (!force && (_lists.containsKey(kind) || _loading[kind] == true)) return;
    setState(() => _loading[kind] = true);
    final access = await MediaCatalog.ensureAccess(kind);
    if (!mounted) return;
    _access[kind] = access;
    if (access == 'denied') {
      setState(() {
        _loading[kind] = false;
        _lists[kind] = const [];
      });
      return;
    }
    await _subs.remove(kind)?.cancel();
    _subs[kind] = MediaCatalog.load(kind).listen(
      (list) {
        if (!mounted) return;
        setState(() {
          _lists[kind] = list;
          if (debugPickerAutoSelect > 0 && list.length >= debugPickerAutoSelect && _selected.isEmpty) {
            for (final e in list.take(debugPickerAutoSelect)) {
              _selected[e.key] = e;
            }
            debugPickerAutoSelect = 0;
          }
        });
      },
      onError: (Object e) {
        if (mounted) setState(() => _loading[kind] = false);
      },
      onDone: () {
        if (mounted) setState(() => _loading[kind] = false);
      },
    );
  }

  List<MediaEntry> get _all => _lists[_kind] ?? const [];

  List<MediaEntry> get _visible {
    final q = _query.trim().toLowerCase();
    return [
      for (final e in _all)
        if ((q.isEmpty || e.lower.contains(q)) &&
            switch (_filter) {
              'socialsave' => e.isSocialSave,
              'camera' => e.isCamera,
              'downloads' => e.isDownload,
              'whatsapp' => e.isWhatsApp,
              'folder' => _folder == null || e.bucket == _folder,
              _ => true,
            })
          e,
    ];
  }

  void _toggle(MediaEntry e) {
    setState(() {
      if (_selected.remove(e.key) == null) _selected[e.key] = e;
    });
  }

  Future<void> _send() async {
    if (_selected.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(_selected.values.toList());
      if (mounted) setState(_selected.clear);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final visible = _visible;
    final loading = _loading[_kind] == true;
    final access = _access[_kind];
    final allSelected = visible.isNotEmpty && visible.every((e) => _selected.containsKey(e.key));
    final folders = <String, int>{};
    for (final e in _all) {
      if (e.bucket.isNotEmpty) folders[e.bucket] = (folders[e.bucket] ?? 0) + 1;
    }
    final folderNames = folders.keys.toList()..sort((a, b) => folders[b]!.compareTo(folders[a]!));
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 1100 ? 6 : width >= 800 ? 5 : width >= 560 ? 4 : 3;

    Widget chip(String id, String label, {IconData? icon}) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ChoiceChip(
            key: ValueKey('pick-chip-$id'),
            avatar: icon == null ? null : Icon(icon, size: 16),
            label: Text(label),
            selected: _filter == id,
            onSelected: (_) => setState(() {
              _filter = id;
              if (id != 'folder') _folder = null;
            }),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('pick-search'),
                  controller: _search,
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search_rounded),
                    hintText: switch (_kind) {
                      MediaKind.video => 'Search videos',
                      MediaKind.image => 'Search photos',
                      MediaKind.audio => 'Search music',
                    },
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => setState(() {
                              _search.clear();
                              _query = '';
                            }),
                          ),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filledTonal(
                key: const ValueKey('pick-browse-files'),
                tooltip: 'Browse files (any type)',
                onPressed: widget.enabled ? widget.onBrowseFiles : null,
                icon: const Icon(Icons.folder_open_rounded),
              ),
            ],
          ),
        ),
        if (Plat.isAndroid)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: LiquidOrSegmented<MediaKind>(
              key: const ValueKey('pick-kind'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: MediaKind.video, icon: Icon(Icons.movie_rounded), label: Text('Videos')),
                ButtonSegment(value: MediaKind.image, icon: Icon(Icons.photo_rounded), label: Text('Photos')),
                ButtonSegment(value: MediaKind.audio, icon: Icon(Icons.music_note_rounded), label: Text('Music')),
              ],
              selected: _kind,
              onSelectionChanged: (s) {
                setState(() {
                  _kind = s.first;
                  _filter = 'all';
                  _folder = null;
                });
                unawaited(_load(_kind));
              },
            ),
          ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
            children: [
              chip('all', switch (_kind) {
                MediaKind.video => 'All videos',
                MediaKind.image => 'All photos',
                MediaKind.audio => 'All music',
              }),
              if (_kind != MediaKind.audio) chip('socialsave', 'SocialSave', icon: Icons.bookmark_rounded),
              if (Plat.isAndroid && _kind != MediaKind.audio) chip('camera', 'Camera', icon: Icons.photo_camera_rounded),
              chip('downloads', 'Downloads', icon: Icons.download_rounded),
              if (Plat.isAndroid) chip('whatsapp', 'WhatsApp', icon: Icons.chat_rounded),
              chip('folder', _folder == null ? 'Folders' : _folder!, icon: Icons.folder_rounded),
            ],
          ),
        ),
        if (_filter == 'folder' && folderNames.isNotEmpty)
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
              children: [
                for (final f in folderNames)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: FilterChip(
                      visualDensity: VisualDensity.compact,
                      label: Text('$f · ${folders[f]}'),
                      selected: _folder == f,
                      onSelected: (on) => setState(() => _folder = on ? f : null),
                    ),
                  ),
              ],
            ),
          ),
        if (access == 'limited')
          Material(
            color: scheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'SocialSave can only see the items you picked.',
                      style: TextStyle(color: scheme.onTertiaryContainer),
                    ),
                  ),
                  TextButton(onPressed: () => _load(_kind, force: true), child: const Text('Select more')),
                  TextButton(onPressed: openAppSettings, child: const Text('Allow all')),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  loading && _all.isEmpty
                      ? 'Loading…'
                      : '${visible.length} ${_kind == MediaKind.video ? 'videos' : _kind == MediaKind.image ? 'photos' : 'songs'}'
                          '${loading ? ' · loading more…' : ''}'
                          '${_selected.isEmpty ? '' : ' · ${_selected.length} selected'}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              TextButton.icon(
                key: const ValueKey('pick-select-all'),
                onPressed: visible.isEmpty
                    ? null
                    : () => setState(() {
                          if (allSelected) {
                            for (final e in visible) {
                              _selected.remove(e.key);
                            }
                          } else {
                            for (final e in visible) {
                              _selected[e.key] = e;
                            }
                          }
                        }),
                icon: Icon(allSelected ? Icons.deselect_rounded : Icons.select_all_rounded, size: 18),
                label: Text(allSelected ? 'Clear' : 'Select all'),
              ),
            ],
          ),
        ),
        Expanded(
          child: access == 'denied'
              ? _Empty(
                  icon: Icons.lock_outline_rounded,
                  text: 'SocialSave needs permission to show your ${_kind == MediaKind.video ? 'videos' : _kind == MediaKind.image ? 'photos' : 'music'}.',
                  action: TextButton(onPressed: openAppSettings, child: const Text('Open settings')),
                )
              : visible.isEmpty
                  ? (loading
                      ? const Center(child: CircularProgressIndicator())
                      : _Empty(
                          icon: Icons.search_off_rounded,
                          text: _query.isEmpty ? 'Nothing here' : 'No match for "$_query"',
                        ))
                  : _kind == MediaKind.audio
                      ? ListView.builder(
                          padding: const EdgeInsets.fromLTRB(8, 4, 8, 96),
                          itemCount: visible.length,
                          itemBuilder: (context, i) {
                            final e = visible[i];
                            final on = _selected.containsKey(e.key);
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: on ? scheme.primary : scheme.secondaryContainer,
                                child: Icon(on ? Icons.check_rounded : Icons.music_note_rounded,
                                    color: on ? scheme.onPrimary : scheme.onSecondaryContainer),
                              ),
                              title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text([_duration(e.durationMs), formatBytes(e.size), e.bucket]
                                  .where((s) => s.isNotEmpty)
                                  .join(' · ')),
                              onTap: () => _toggle(e),
                            );
                          },
                        )
                      : GridView.builder(
                          key: const ValueKey('pick-grid'),
                          padding: const EdgeInsets.fromLTRB(8, 4, 8, 96),
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            mainAxisSpacing: 6,
                            crossAxisSpacing: 6,
                            childAspectRatio: 0.78,
                          ),
                          itemCount: visible.length,
                          itemBuilder: (context, i) {
                            final e = visible[i];
                            return _Tile(
                              key: ValueKey(e.key),
                              entry: e,
                              selected: _selected.containsKey(e.key),
                              onTap: () => _toggle(e),
                            );
                          },
                        ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          child: _selected.isEmpty
              ? const SizedBox(width: double.infinity)
              : Material(
                  elevation: 6,
                  color: scheme.surfaceContainerHigh,
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: Row(
                        children: [
                          TextButton(
                            onPressed: () => setState(_selected.clear),
                            child: const Text('Clear'),
                          ),
                          const Spacer(),
                          Text(
                            formatBytes(_selected.values.fold(0, (a, b) => a + b.size)),
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(width: 12),
                          FilledButton.icon(
                            key: const ValueKey('pick-send'),
                            onPressed: widget.enabled && !_sending ? _send : null,
                            icon: _sending
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.send_rounded),
                            label: Text('Send (${_selected.length})'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: scheme.outline),
            const SizedBox(height: 8),
            Text(text, textAlign: TextAlign.center),
            if (action != null) action!,
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({super.key, required this.entry, required this.selected, required this.onTap});
  final MediaEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final e = entry;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _Thumb(entry: e),
                  if (e.durationMs > 0)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          child: Text(_duration(e.durationMs),
                              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ),
                  if (selected) ColoredBox(color: scheme.primary.withValues(alpha: 0.28)),
                  Positioned(
                    left: 4,
                    top: 4,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: selected ? scheme.primary : Colors.black26,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: selected ? Icon(Icons.check_rounded, size: 16, color: scheme.onPrimary) : null,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelMedium),
                  Text(formatBytes(e.size), style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Loads the thumbnail after the tile has been on screen briefly, so a fast
/// fling through thousands of items does not queue thousands of decodes.
class _Thumb extends StatefulWidget {
  const _Thumb({required this.entry});
  final MediaEntry entry;

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  Timer? _wait;
  String? _path;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _wait = Timer(const Duration(milliseconds: 120), _fetch);
  }

  Future<void> _fetch() async {
    final path = widget.entry.kind == MediaKind.image && widget.entry.path != null && Plat.isWindows
        ? widget.entry.path
        : await MediaCatalog.thumbnail(widget.entry);
    if (!mounted) return;
    setState(() {
      _path = path;
      _failed = path == null;
    });
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final path = _path;
    if (path == null) {
      return ColoredBox(
        color: scheme.surfaceContainerHigh,
        child: Icon(
          widget.entry.kind == MediaKind.image ? Icons.photo_rounded : Icons.movie_rounded,
          color: _failed ? scheme.outline : scheme.outlineVariant,
        ),
      );
    }
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      cacheWidth: 320,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => ColoredBox(color: scheme.surfaceContainerHigh, child: Icon(Icons.movie_rounded, color: scheme.outline)),
    );
  }
}
