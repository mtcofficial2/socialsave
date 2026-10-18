import 'dart:io';
import 'dart:ui';

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/audio/audio_service.dart';
import 'package:social_save/features/library/nearby_service.dart';
import 'package:social_save/features/library/nearby_ui.dart';
import 'package:social_save/features/player/presentation/screens/in_app_player_screen.dart';

String _fmt(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '${m}:${s.toString().padLeft(2, "0")}';
}

/// Square album art with a graceful fallback.
class AlbumArt extends StatelessWidget {
  const AlbumArt({super.key, required this.song, this.size = 48, this.radius = 10});
  final Song? song;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(radius)),
      child: Icon(Icons.music_note_rounded, size: size * 0.5, color: scheme.onSecondaryContainer),
    );
    final s = song;
    if (s == null) return fallback;
    return FutureBuilder<String?>(
      future: AudioLibrary.instance.artFor(s),
      builder: (context, snap) {
        final path = snap.data;
        if (path == null) return fallback;
        return ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Image.file(File(path), width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, __, ___) => fallback),
        );
      },
    );
  }
}

/// Opens a picker of nearby devices and sends the song file.
Future<void> sendSong(BuildContext context, Song s) async {
  final path = s.path;
  if (path == null || !File(path).existsSync()) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This song is not available as a file to send.')));
    return;
  }
  NearbyService.ping();
  final list = NearbyService.devices.value;
  if (list.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('No nearby device yet. Open Send / Receive to connect first.'),
        action: SnackBarAction(label: 'Open', onPressed: () => context.push('/share')),
      ),
    );
    return;
  }
  final d = await showModalBottomSheet<NearbyDevice>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(title: Text('Send "${s.title}" to', style: const TextStyle(fontWeight: FontWeight.w700))),
          for (final d in list)
            ListTile(
              leading: Icon(d.isPc ? Icons.computer_rounded : Icons.smartphone_rounded),
              title: Text(d.name.isEmpty ? d.playerName : d.name),
              onTap: () => Navigator.pop(ctx, d),
            ),
          ListTile(leading: const Icon(Icons.swap_horiz_rounded), title: const Text('More ways (Send / Receive)'), onTap: () {
            Navigator.pop(ctx);
            context.push('/share');
          }),
        ],
      ),
    ),
  );
  if (d != null && context.mounted) await sendToNearby(context, d, File(path));
}

class MusicScreen extends StatefulWidget {
  const MusicScreen({super.key});

  @override
  State<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends State<MusicScreen> {
  final _lib = AudioLibrary.instance;
  final _ctl = AudioController.instance;
  String _q = '';
  bool _searching = false;
  SongSort _sort = SongSort.recent;

  @override
  void initState() {
    super.initState();
    AudioController.videoPlayerOpen = () => InAppPlayerScreen.openCount > 0;
    _ctl.restore();
    _lib.load();
  }

  List<Song> get _songs {
    var l = _lib.songs;
    if (_q.isNotEmpty) {
      final q = _q.toLowerCase();
      l = [for (final s in l) if ('${s.title} ${s.artist} ${s.album}'.toLowerCase().contains(q)) s];
    }
    return _lib.sorted(l, _sort);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 6,
      child: Scaffold(
        appBar: AppBar(
          title: _searching
              ? TextField(
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'Search songs, artists, albums', border: InputBorder.none),
                  onChanged: (v) => setState(() => _q = v.trim()),
                )
              : const Text('Music'),
          actions: [
            IconButton(
              tooltip: _searching ? 'Close search' : 'Search',
              icon: Icon(_searching ? Icons.close_rounded : Icons.search_rounded),
              onPressed: () => setState(() {
                _searching = !_searching;
                if (!_searching) _q = '';
              }),
            ),
            PopupMenuButton<SongSort>(
              tooltip: 'Sort songs',
              icon: const Icon(Icons.sort_rounded),
              onSelected: (v) => setState(() => _sort = v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: SongSort.recent, child: Text('Recently added')),
                PopupMenuItem(value: SongSort.title, child: Text('Title')),
                PopupMenuItem(value: SongSort.artist, child: Text('Artist')),
                PopupMenuItem(value: SongSort.duration, child: Text('Longest first')),
              ],
            ),
            PopupMenuButton<String>(
              tooltip: 'Music settings',
              onSelected: (_) => _ctl.setRestoreSession(!_ctl.restoreSession),
              itemBuilder: (_) => [
                CheckedPopupMenuItem(value: 'restore', checked: _ctl.restoreSession, child: const Text('Restore last session')),
              ],
            ),
            if (Plat.isWindows)
              IconButton(
                tooltip: 'Add a music folder',
                icon: const Icon(Icons.create_new_folder_outlined),
                onPressed: () async {
                  final dir = await fs.getDirectoryPath();
                  if (dir != null) await _lib.addFolder(dir);
                },
              ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Songs'),
              Tab(text: 'Albums'),
              Tab(text: 'Artists'),
              Tab(text: 'Folders'),
              Tab(text: 'Playlists'),
              Tab(text: 'Favorites'),
            ],
          ),
        ),
        body: ListenableBuilder(
          listenable: Listenable.merge([_lib, _ctl]),
          builder: (context, _) {
            if (_lib.loading && !_lib.loaded) return const Center(child: CircularProgressIndicator());
            if (_lib.denied) return _permission(context);
            if (_lib.songs.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_lib.error.isNotEmpty ? _lib.error : (Plat.isWindows ? 'No music found in your Music folder. Use the folder button to add more.' : 'No music found on this phone.'), textAlign: TextAlign.center),
                ),
              );
            }
            final songs = _songs;
            return Column(
              children: [
                Expanded(
                  child: TabBarView(
                    children: [
                      _songList(songs),
                      _groups(songs, (s) => s.album),
                      _groups(songs, (s) => s.artist),
                      _groups(songs, (s) => s.folder),
                      _playlists(songs),
                      _songList([for (final s in songs) if (_ctl.isFavorite(s)) s], empty: 'Tap the heart on a song to add it here.'),
                    ],
                  ),
                ),
                const MiniAudioBar(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _permission(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.library_music_rounded, size: 72, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text('Let SocialSave see your music', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            const Text('To show and play the songs on your phone, SocialSave needs permission to read audio files. It never uploads or changes them.', textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton(onPressed: () => _lib.load(force: true), child: const Text('Allow access')),
            TextButton(onPressed: openAppSettings, child: const Text('Open app settings')),
          ],
        ),
      ),
    );
  }

  Widget _songList(List<Song> songs, {String empty = 'Nothing here.'}) {
    if (songs.isEmpty) return Center(child: Text(empty));
    return ListView.builder(
      itemCount: songs.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _ctl.playQueue(songs, 0, shuffleOn: false),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text('Play all (${songs.length})'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => _ctl.playQueue(songs, 0, shuffleOn: true),
                  icon: const Icon(Icons.shuffle_rounded),
                  label: const Text('Shuffle'),
                ),
              ],
            ),
          );
        }
        final s = songs[i - 1];
        return SongTile(song: s, onTap: () => _ctl.playQueue(songs, i - 1));
      },
    );
  }

  Widget _groups(List<Song> songs, String Function(Song) by) {
    final map = <String, List<Song>>{};
    for (final s in songs) {
      map.putIfAbsent(by(s), () => []).add(s);
    }
    final keys = map.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return ListView.builder(
      itemCount: keys.length,
      itemBuilder: (context, i) {
        final k = keys[i];
        final list = map[k]!;
        return ListTile(
          leading: AlbumArt(song: list.first, size: 48),
          title: Text(k, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${list.length} ${list.length == 1 ? 'song' : 'songs'}'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SongListPage(title: k, songs: list))),
        );
      },
    );
  }

  Widget _playlists(List<Song> songs) {
    final byKey = {for (final s in _lib.songs) s.key: s};
    return ListView(
      children: [
        ListTile(
          leading: const Icon(Icons.add_circle_outline_rounded),
          title: const Text('New playlist'),
          onTap: () async {
            final name = await _askName(context);
            if (name != null) _ctl.createPlaylist(name);
          },
        ),
        ListTile(
          leading: const Icon(Icons.history_rounded),
          title: const Text('Recently added'),
          subtitle: const Text('Your 50 newest songs'),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => SongListPage(title: 'Recently added', songs: _lib.sorted(_lib.songs, SongSort.recent).take(50).toList()))),
        ),
        for (final e in _ctl.playlists.entries)
          ListTile(
            leading: const Icon(Icons.queue_music_rounded),
            title: Text(e.key),
            subtitle: Text('${e.value.length} songs'),
            trailing: IconButton(tooltip: 'Delete playlist', icon: const Icon(Icons.delete_outline_rounded), onPressed: () => _ctl.deletePlaylist(e.key)),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => SongListPage(title: e.key, songs: [for (final k in e.value) if (byKey[k] != null) byKey[k]!]))),
          ),
      ],
    );
  }
}

Future<String?> _askName(BuildContext context) async {
  final c = TextEditingController();
  final v = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('New playlist'),
      content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(hintText: 'Name')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Create')),
      ],
    ),
  );
  c.dispose();
  return v;
}

class SongListPage extends StatelessWidget {
  const SongListPage({super.key, required this.title, required this.songs});
  final String title;
  final List<Song> songs;

  @override
  Widget build(BuildContext context) {
    final ctl = AudioController.instance;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Column(
        children: [
          Expanded(
            child: songs.isEmpty
                ? const Center(child: Text('No songs yet. Use the menu on a song to add it.'))
                : ListView.builder(
                    itemCount: songs.length,
                    itemBuilder: (_, i) => SongTile(song: songs[i], onTap: () => ctl.playQueue(songs, i)),
                  ),
          ),
          const MiniAudioBar(),
        ],
      ),
    );
  }
}

class SongTile extends StatelessWidget {
  const SongTile({super.key, required this.song, required this.onTap});
  final Song song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ctl = AudioController.instance;
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final playingThis = ctl.current?.key == song.key;
        final fav = ctl.isFavorite(song);
        return Semantics(
          label: '${song.title} by ${song.artist}${playingThis ? ', now playing' : ''}',
          child: ListTile(
            leading: AlbumArt(song: song),
            title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: playingThis ? FontWeight.w800 : FontWeight.w600, color: playingThis ? Theme.of(context).colorScheme.primary : null)),
            subtitle: Text(song.durationMs > 0 ? '${song.artist} · ${_fmt(Duration(milliseconds: song.durationMs))}' : song.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () {
              HapticFeedback.selectionClick();
              onTap();
            },
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: fav ? 'Remove from favorites' : 'Add to favorites',
                  icon: Icon(fav ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: fav ? Colors.redAccent : null),
                  onPressed: () => ctl.toggleFavorite(song),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More for ${song.title}',
                  onSelected: (v) async {
                    switch (v) {
                      case 'next':
                        ctl.playNext(song);
                      case 'queue':
                        ctl.addToQueue(song);
                      case 'send':
                        await sendSong(context, song);
                      case 'playlist':
                        final names = ctl.playlists.keys.toList();
                        final pick = await showModalBottomSheet<String>(
                          context: context,
                          builder: (ctx) => SafeArea(
                            child: ListView(
                              shrinkWrap: true,
                              children: [
                                const ListTile(title: Text('Add to playlist')),
                                if (names.isEmpty) const ListTile(title: Text('No playlists yet. Create one in the Playlists tab.')),
                                for (final n in names) ListTile(title: Text(n), onTap: () => Navigator.pop(ctx, n)),
                              ],
                            ),
                          ),
                        );
                        if (pick != null) ctl.addToPlaylist(pick, song);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'next', child: Text('Play next')),
                    PopupMenuItem(value: 'queue', child: Text('Add to queue')),
                    PopupMenuItem(value: 'playlist', child: Text('Add to playlist')),
                    PopupMenuItem(value: 'send', child: Text('Send to a nearby device')),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Slim player docked above the navigation bar.
class MiniAudioBar extends StatefulWidget {
  const MiniAudioBar({super.key});

  @override
  State<MiniAudioBar> createState() => _MiniAudioBarState();
}

class _MiniAudioBarState extends State<MiniAudioBar> {
  @override
  void initState() {
    super.initState();
    AudioController.videoPlayerOpen = () => InAppPlayerScreen.openCount > 0;
    AudioController.instance.restore();
  }

  @override
  Widget build(BuildContext context) {
    final ctl = AudioController.instance;
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final s = ctl.current;
        return AnimatedSize(
          duration: const Duration(milliseconds: 220),
          child: s == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Dismissible(
                    key: const ValueKey('mini-audio-dismiss'),
                    direction: DismissDirection.horizontal,
                    onDismissed: (_) => ctl.close(),
                    child: GestureDetector(
                    onVerticalDragEnd: (d) {
                      if ((d.primaryVelocity ?? 0) > 300) ctl.close();
                    },
                    child: Material(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(22),
                    clipBehavior: Clip.antiAlias,
                    child: Semantics(
                      label: 'Now playing ${s.title} by ${s.artist}. Tap to open the player.',
                      button: true,
                      child: InkWell(
                        onTap: () => Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
                          pageBuilder: (_, a, __) => const NowPlayingScreen(),
                          transitionsBuilder: (_, a, __, child) => SlideTransition(
                            position: Tween(begin: const Offset(0, 1), end: Offset.zero).chain(CurveTween(curve: Curves.easeOutCubic)).animate(a),
                            child: child,
                          ),
                        )),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 6, 4, 4),
                              child: Row(
                                children: [
                                  AlbumArt(song: s, size: 44, radius: 12),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                                        Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                                      ],
                                    ),
                                  ),
                                  IconButton(tooltip: ctl.playing ? 'Pause' : 'Play', icon: Icon(ctl.playing ? Icons.pause_rounded : Icons.play_arrow_rounded), onPressed: () {
                                    HapticFeedback.lightImpact();
                                    ctl.toggle();
                                  }),
                                  IconButton(tooltip: 'Next song', icon: const Icon(Icons.skip_next_rounded), onPressed: ctl.next),
                                  IconButton(tooltip: 'Close player', icon: const Icon(Icons.close_rounded), onPressed: () {
                                    HapticFeedback.selectionClick();
                                    ctl.close();
                                  }),
                                ],
                              ),
                            ),
                            ValueListenableBuilder<Duration>(
                              valueListenable: ctl.position,
                              builder: (_, pos, __) {
                                final total = ctl.duration.inMilliseconds > 0 ? ctl.duration.inMilliseconds : s.durationMs;
                                return LinearProgressIndicator(minHeight: 2, value: total > 0 ? (pos.inMilliseconds / total).clamp(0.0, 1.0) : 0);
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  ),
                  ),
                ),
        );
      },
    );
  }
}

class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  final ctl = AudioController.instance;
  String? _schemeKey;
  ColorScheme? _scheme;
  String? _artPath;

  Future<void> _theme(Song s) async {
    if (_schemeKey == s.key) return;
    _schemeKey = s.key;
    final path = await AudioLibrary.instance.artFor(s);
    ColorScheme? scheme;
    if (path != null && mounted) {
      try {
        scheme = await ColorScheme.fromImageProvider(provider: FileImage(File(path)), brightness: Brightness.dark);
      } catch (_) {}
    }
    if (mounted && _schemeKey == s.key) {
      setState(() {
        _scheme = scheme;
        _artPath = path;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final s = ctl.current;
        if (s == null) return const Scaffold(body: Center(child: Text('Nothing playing')));
        _theme(s);
        final base = Theme.of(context);
        final scheme = _scheme ?? ColorScheme.fromSeed(seedColor: base.colorScheme.primary, brightness: Brightness.dark);
        return Theme(
          data: base.copyWith(colorScheme: scheme),
          child: Scaffold(
            backgroundColor: scheme.surface,
            body: Stack(
              fit: StackFit.expand,
              children: [
                if (_artPath != null)
                  ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
                    child: Image.file(File(_artPath!), fit: BoxFit.cover),
                  ),
                ColoredBox(color: scheme.surface.withValues(alpha: _artPath != null ? 0.72 : 1)),
                SafeArea(
                  child: Column(
                    children: [
                      Row(
                        children: [
                          IconButton(tooltip: 'Close player', icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32), onPressed: () => Navigator.pop(context)),
                          const Expanded(child: Center(child: Text('Now playing', style: TextStyle(fontWeight: FontWeight.w700)))),
                          IconButton(tooltip: 'Send this song', icon: const Icon(Icons.send_rounded), onPressed: () => sendSong(context, s)),
                          IconButton(tooltip: 'Close player', icon: const Icon(Icons.close_rounded), onPressed: () {
                            ctl.close();
                            Navigator.pop(context);
                          }),
                        ],
                      ),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, c) {
                            final art = (c.maxHeight * 0.55).clamp(160.0, 340.0);
                            return SingleChildScrollView(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(minHeight: c.maxHeight),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    AnimatedSwitcher(
                                      duration: const Duration(milliseconds: 300),
                                      child: Container(
                                        key: ValueKey(s.key),
                                        decoration: BoxDecoration(boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 30, offset: const Offset(0, 14))], borderRadius: BorderRadius.circular(24)),
                                        child: AlbumArt(song: s, size: art, radius: 24),
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 28),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                                                Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurfaceVariant)),
                                              ],
                                            ),
                                          ),
                                          IconButton(
                                            tooltip: ctl.isFavorite(s) ? 'Remove from favorites' : 'Add to favorites',
                                            icon: Icon(ctl.isFavorite(s) ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: ctl.isFavorite(s) ? Colors.redAccent : null),
                                            onPressed: () => ctl.toggleFavorite(s),
                                          ),
                                        ],
                                      ),
                                    ),
                                    _seek(s),
                                    _controls(context),
                                    _extras(context),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _seek(Song s) {
    return ValueListenableBuilder<Duration>(
      valueListenable: ctl.position,
      builder: (context, pos, _) {
        final total = ctl.duration.inMilliseconds > 0 ? ctl.duration : Duration(milliseconds: s.durationMs);
        final max = total.inMilliseconds.toDouble();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              Semantics(
                label: 'Seek bar, ${_fmt(pos)} of ${_fmt(total)}',
                child: Slider(
                  value: max > 0 ? pos.inMilliseconds.clamp(0, total.inMilliseconds).toDouble() : 0,
                  max: max > 0 ? max : 1,
                  onChanged: max > 0 ? (v) => ctl.seek(Duration(milliseconds: v.round())) : null,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(_fmt(pos)), Text(_fmt(total))]),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _controls(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(tooltip: ctl.shuffle ? 'Shuffle on' : 'Shuffle off', icon: Icon(Icons.shuffle_rounded, color: ctl.shuffle ? scheme.primary : null), onPressed: () {
          HapticFeedback.selectionClick();
          ctl.toggleShuffle();
        }),
        IconButton(iconSize: 38, tooltip: 'Previous song', icon: const Icon(Icons.skip_previous_rounded), onPressed: () {
          HapticFeedback.lightImpact();
          ctl.previous();
        }),
        const SizedBox(width: 6),
        IconButton.filled(
          iconSize: 42,
          tooltip: ctl.playing ? 'Pause' : 'Play',
          icon: AnimatedSwitcher(duration: const Duration(milliseconds: 180), child: Icon(ctl.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, key: ValueKey(ctl.playing))),
          onPressed: () {
            HapticFeedback.mediumImpact();
            ctl.toggle();
          },
        ),
        const SizedBox(width: 6),
        IconButton(iconSize: 38, tooltip: 'Next song', icon: const Icon(Icons.skip_next_rounded), onPressed: () {
          HapticFeedback.lightImpact();
          ctl.next();
        }),
        IconButton(
          tooltip: 'Repeat: ${ctl.repeat.name}',
          icon: Icon(ctl.repeat == AudioRepeat.one ? Icons.repeat_one_rounded : Icons.repeat_rounded, color: ctl.repeat != AudioRepeat.off ? scheme.primary : null),
          onPressed: () {
            HapticFeedback.selectionClick();
            ctl.cycleRepeat();
          },
        ),
      ],
    );
  }

  Widget _extras(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          PopupMenuButton<double>(
            tooltip: 'Playback speed',
            onSelected: ctl.setSpeed,
            itemBuilder: (_) => [for (final v in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]) PopupMenuItem(value: v, child: Text('${v}x'))],
            child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [const Icon(Icons.speed_rounded), const SizedBox(width: 4), Text('${ctl.speed}x')])),
          ),
          PopupMenuButton<int>(
            tooltip: 'Sleep timer',
            onSelected: (m) => ctl.setSleep(m == 0 ? null : Duration(minutes: m)),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 0, child: Text('Off')),
              PopupMenuItem(value: 15, child: Text('15 minutes')),
              PopupMenuItem(value: 30, child: Text('30 minutes')),
              PopupMenuItem(value: 45, child: Text('45 minutes')),
              PopupMenuItem(value: 60, child: Text('1 hour')),
            ],
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Icon(ctl.sleepAt != null ? Icons.bedtime_rounded : Icons.bedtime_outlined),
                const SizedBox(width: 4),
                Text(ctl.sleepAt != null ? 'On' : 'Sleep'),
              ]),
            ),
          ),
          TextButton.icon(
            onPressed: () => _queue(context),
            icon: const Icon(Icons.queue_music_rounded),
            label: const Text('Queue'),
          ),
        ],
      ),
    );
  }

  void _queue(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (ctx, scroll) => ListenableBuilder(
          listenable: ctl,
          builder: (ctx, _) => ReorderableListView.builder(
            scrollController: scroll,
            itemCount: ctl.queue.length,
            onReorder: ctl.move,
            itemBuilder: (ctx, i) {
              final s = ctl.queue[i];
              final cur = i == ctl.index;
              return ListTile(
                key: ValueKey('q-${i}-${s.key}'),
                leading: AlbumArt(song: s, size: 40),
                title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: cur ? FontWeight.w800 : null)),
                subtitle: Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => ctl.playQueue(ctl.queue, i),
                trailing: cur ? const Icon(Icons.equalizer_rounded) : IconButton(tooltip: 'Remove from queue', icon: const Icon(Icons.close_rounded), onPressed: () => ctl.removeAt(i)),
              );
            },
          ),
        ),
      ),
    );
  }
}