import 'dart:io';
import 'dart:ui';

import 'package:file_selector/file_selector.dart' as fs;
import 'package:social_save/shared/widgets/premium_glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/audio/audio_service.dart';
import 'package:social_save/features/library/nearby_service.dart';
import 'package:social_save/features/library/nearby_ui.dart';
import 'package:social_save/features/player/presentation/screens/in_app_player_screen.dart';
import 'package:social_save/shared/widgets/liquid_glass.dart';

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
              onSelected: (v) {
                switch (v) {
                  case 'restore':
                    _ctl.setRestoreSession(!_ctl.restoreSession);
                  case 'rescan':
                    _lib.rescan();
                  case 'system':
                    _lib.setFilters(system: !_lib.hideSystemSounds);
                  case 'short':
                    _lib.setFilters(short: !_lib.hideShortClips);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rescan', child: ListTile(dense: true, contentPadding: EdgeInsets.zero, leading: Icon(Icons.refresh_rounded), title: Text('Rescan music'))),
                CheckedPopupMenuItem(value: 'system', checked: _lib.hideSystemSounds, child: const Text('Hide ringtones & notification sounds')),
                CheckedPopupMenuItem(value: 'short', checked: _lib.hideShortClips, child: Text('Hide clips under ${AudioLibrary.minSeconds} s')),
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
              return RefreshIndicator(
                onRefresh: _lib.rescan,
                child: ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
                  const SizedBox(height: 160),
                  Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_lib.error.isNotEmpty ? _lib.error : (Plat.isWindows ? 'No music found in your Music folder. Use the folder button to add more.' : 'No music found on this phone. Pull down to rescan.'), textAlign: TextAlign.center),
                  ),
                ]),
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
    return RefreshIndicator(
      onRefresh: _lib.rescan,
      child: _songListView(songs),
    );
  }

  Widget _songListView(List<Song> songs) {
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
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
const _tabularFigures = [FontFeature.tabularFigures()];

/// Opens the full player. The page slides up. A full-screen fade made this
/// open late on the phone.
void openNowPlaying(BuildContext context) {
  Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 200),
    reverseTransitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (_, a, __) => const NowPlayingScreen(),
    transitionsBuilder: (context, animation, _, child) {
      if (MediaQuery.disableAnimationsOf(context)) return child;
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
      return SlideTransition(
        position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(curved),
        child: child,
      );
    },
  ));
}

/// 1.0.45: floating, theme-aware mini player (light and dark).
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
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final s = ctl.current;
        return AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
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
                        final v = d.primaryVelocity ?? 0;
                        if (v > 300) ctl.close();
                        if (v < -300) openNowPlaying(context);
                      },
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: dark ? 0.35 : 0.10),
                              blurRadius: 24,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: _MiniDockFill(
                            glass: LiquidGlassScope.of(context),
                            child: Material(
                              color: LiquidGlassScope.of(context)
                                  ? Colors.transparent
                                  : scheme.surfaceContainerHigh.withValues(alpha: dark ? 0.82 : 0.90),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                                side: BorderSide(color: scheme.outlineVariant.withValues(alpha: dark ? 0.25 : 0.5)),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Semantics(
                                label: 'Now playing ${s.title} by ${s.artist}. Tap to open the player.',
                                button: true,
                                child: InkWell(
                                  onTap: () => openNowPlaying(context),
                                  child: Stack(
                                    children: [
                                      if (LiquidGlassScope.of(context)) ...[
                                        Positioned.fill(
                                          child: ColoredBox(
                                            color: scheme.surface.withValues(alpha: dark ? 0.55 : 0.70),
                                          ),
                                        ),
                                        Positioned.fill(
                                          child: IgnorePointer(
                                            child: IosGlassPlate(dark: dark, radius: 20),
                                          ),
                                        ),
                                      ],
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(8, 8, 6, 8),
                                        child: Row(
                                          children: [
                                            AnimatedSwitcher(
                                              duration: const Duration(milliseconds: 250),
                                              child: AlbumArt(key: ValueKey(s.key), song: s, size: 42, radius: 11),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(
                                                    s.title,
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: TextStyle(color: scheme.onSurface, fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: -0.1),
                                                  ),
                                                  const SizedBox(height: 1),
                                                  Text(
                                                    s.artist,
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            _QuietIcon(
                                              icon: ctl.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                              label: ctl.playing ? 'Pause' : 'Play',
                                              size: 26,
                                              onTap: () {
                                                HapticFeedback.lightImpact();
                                                ctl.toggle();
                                              },
                                            ),
                                            _QuietIcon(icon: Icons.skip_next_rounded, label: 'Next song', size: 24, onTap: ctl.next),
                                            _QuietIcon(
                                              icon: Icons.close_rounded,
                                              label: 'Close player',
                                              size: 18,
                                              dim: true,
                                              onTap: () {
                                                HapticFeedback.selectionClick();
                                                ctl.close();
                                              },
                                            ),
                                          ],
                                        ),
                                      ),
                                      Positioned(
                                        left: 14,
                                        right: 14,
                                        bottom: 0,
                                        child: ValueListenableBuilder<Duration>(
                                          valueListenable: ctl.position,
                                          builder: (_, pos, __) {
                                            final total = ctl.duration.inMilliseconds > 0 ? ctl.duration.inMilliseconds : s.durationMs;
                                            final f = total > 0 ? (pos.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;
                                            return ClipRRect(
                                              borderRadius: BorderRadius.circular(2),
                                              child: SizedBox(
                                                height: 2,
                                                child: Stack(
                                                  children: [
                                                    Positioned.fill(child: ColoredBox(color: scheme.onSurface.withValues(alpha: 0.08))),
                                                    FractionallySizedBox(widthFactor: f, child: ColoredBox(color: scheme.primary)),
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
                              ),
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

/// Frosts the mini player when liquid glass is off. The glass look is painted
/// inside the dock, so this adds no second blur.
class _MiniDockFill extends StatelessWidget {
  const _MiniDockFill({required this.glass, required this.child});

  final bool glass;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (glass) return child;
    return BackdropFilter(
      filter: GlassTokens.blur(24),
      child: child,
    );
  }
}

/// Icon without a plate; a soft theme-tinted circle on hover or press.
class _QuietIcon extends StatefulWidget {
  const _QuietIcon({required this.icon, required this.label, required this.onTap, this.size = 24, this.box = 40, this.dim = false, this.color});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final double size;
  final double box;
  final bool dim;
  final Color? color;

  @override
  State<_QuietIcon> createState() => _QuietIconState();
}

class _QuietIconState extends State<_QuietIcon> {
  bool _hover = false;
  bool _down = false;

  Widget _plate(bool lit, ColorScheme scheme, Widget child) {
    if (!LiquidGlassScope.of(context) || widget.box < 48) {
      return AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        width: widget.box,
        height: widget.box,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: scheme.onSurface.withValues(alpha: lit ? 0.08 : 0),
        ),
        child: child,
      );
    }
    return LiquidSquash(
      pressed: _down,
      child: IosGlassPlate(
        dark: scheme.brightness == Brightness.dark,
        shadow: true,
        child: SizedBox(width: widget.box, height: widget.box, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lit = _hover || _down;
    final base = widget.color ?? (widget.dim ? scheme.onSurfaceVariant : scheme.onSurface);
    return Tooltip(
      message: widget.label,
      waitDuration: const Duration(milliseconds: 600),
      child: Semantics(
        button: true,
        label: widget.label,
        excludeSemantics: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _down = true),
            onTapCancel: () => setState(() => _down = false),
            onTapUp: (_) => setState(() => _down = false),
            onTap: widget.onTap,
            child: _plate(
              lit,
              scheme,
              AnimatedScale(
                scale: _down ? 0.9 : 1,
                duration: const Duration(milliseconds: 120),
                child: Icon(widget.icon, size: widget.size, color: base),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 1.0.45 now-playing screen: large soft art, ambient background that
/// follows the app theme (lighter in light mode), thin seek bar, centred
/// see-through play/pause, quiet shuffle / repeat and one "⋯" menu.
class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  final ctl = AudioController.instance;
  final _focus = FocusNode(debugLabel: 'now-playing');
  String? _schemeKey;
  ColorScheme? _scheme;
  String? _artPath;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _theme(Song s, Brightness brightness) async {
    final key = '${s.key}|${brightness.name}';
    if (_schemeKey == key) return;
    _schemeKey = key;
    final path = await AudioLibrary.instance.artFor(s);
    ColorScheme? scheme;
    if (path != null && mounted) {
      try {
        scheme = await ColorScheme.fromImageProvider(provider: FileImage(File(path)), brightness: brightness);
      } catch (_) {}
    }
    if (mounted && _schemeKey == key) {
      setState(() {
        _scheme = scheme;
        _artPath = path;
      });
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed || HardwareKeyboard.instance.isControlPressed;
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.mediaPlayPause || k == LogicalKeyboardKey.keyK) {
      if (e is KeyDownEvent) ctl.toggle();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.arrowLeft) {
      final forward = k == LogicalKeyboardKey.arrowRight;
      if (shift) {
        if (e is KeyDownEvent) forward ? ctl.next() : ctl.previous();
      } else {
        final total = ctl.duration;
        var t = ctl.position.value + Duration(seconds: forward ? 5 : -5);
        if (t < Duration.zero) t = Duration.zero;
        if (total > Duration.zero && t > total) t = total;
        ctl.seek(t);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaTrackNext || k == LogicalKeyboardKey.keyN) {
      if (e is KeyDownEvent) ctl.next();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaTrackPrevious || k == LogicalKeyboardKey.keyP) {
      if (e is KeyDownEvent) ctl.previous();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      Navigator.maybePop(context);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctl,
      builder: (context, _) {
        final s = ctl.current;
        if (s == null) return const Scaffold(body: Center(child: Text('Nothing playing')));
        final base = Theme.of(context);
        final brightness = base.brightness;
        _theme(s, brightness);
        final light = brightness == Brightness.light;
        final scheme = _scheme ?? ColorScheme.fromSeed(seedColor: base.colorScheme.primary, brightness: brightness);
        return Theme(
          data: base.copyWith(
            colorScheme: scheme,
            popupMenuTheme: PopupMenuThemeData(
              color: scheme.surfaceContainerHigh,
              surfaceTintColor: Colors.transparent,
              elevation: 10,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
              ),
              textStyle: TextStyle(color: scheme.onSurface, fontSize: 14),
            ),
          ),
          child: Builder(
            builder: (context) => Focus(
              focusNode: _focus,
              autofocus: true,
              onKeyEvent: _onKey,
              child: Scaffold(
                backgroundColor: scheme.surface,
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Ambient background: blurred art, washed with the
                    // surface colour (stronger wash in light mode).
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 600),
                      child: _artPath == null
                          ? const SizedBox.expand()
                          : ImageFiltered(
                              key: ValueKey(_artPath),
                              imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60, tileMode: TileMode.mirror),
                              child: Image.file(File(_artPath!), fit: BoxFit.cover, width: double.infinity, height: double.infinity),
                            ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            scheme.surface.withValues(alpha: _artPath != null ? (light ? 0.55 : 0.50) : 0.0),
                            scheme.surface.withValues(alpha: _artPath != null ? (light ? 0.80 : 0.78) : 0.0),
                            scheme.surface.withValues(alpha: light ? 0.96 : 0.94),
                          ],
                          stops: const [0, 0.5, 1],
                        ),
                      ),
                    ),
                    // Soft colour glow behind the art.
                    IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: const Alignment(0, -0.35),
                            radius: 0.9,
                            colors: [
                              scheme.primaryContainer.withValues(alpha: light ? 0.55 : 0.30),
                              scheme.primaryContainer.withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                    ),
                    SafeArea(child: _body(context, s, scheme, light)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _body(BuildContext context, Song s, ColorScheme scheme, bool light) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Row(
            children: [
              _QuietIcon(icon: Icons.keyboard_arrow_down_rounded, label: 'Hide player', size: 28, onTap: () => Navigator.pop(context)),
              Expanded(
                child: Center(
                  child: Text(
                    'NOW PLAYING',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 1.6),
                  ),
                ),
              ),
              _menu(context, s, scheme),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, c) {
              final wide = c.maxWidth > 820 && c.maxHeight < 720;
              final art = wide
                  ? (c.maxHeight * 0.62).clamp(200.0, 420.0)
                  : (c.maxHeight * 0.48).clamp(180.0, 380.0).clamp(0.0, c.maxWidth - 56);
              final artWidget = _art(s, art, scheme, light);
              final info = ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _titleRow(s, scheme),
                    const SizedBox(height: 18),
                    _AudioSeek(ctl: ctl, song: s),
                    const SizedBox(height: 10),
                    _controls(context, scheme),
                    const SizedBox(height: 14),
                    _upNext(context, scheme),
                  ],
                ),
              );
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: c.maxHeight),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: wide
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [artWidget, const SizedBox(width: 56), Flexible(child: info)],
                          )
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [artWidget, const SizedBox(height: 32), info],
                          ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _art(Song s, double size, ColorScheme scheme, bool light) {
    return AnimatedScale(
      scale: ctl.playing ? 1 : 0.94,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 380),
        switchInCurve: Curves.easeOutCubic,
        transitionBuilder: (c, a) => FadeTransition(
          opacity: a,
          child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(a), child: c),
        ),
        child: Container(
          key: ValueKey(s.key),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: (light ? scheme.shadow : Colors.black).withValues(alpha: light ? 0.18 : 0.45),
                blurRadius: light ? 36 : 44,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: AlbumArt(song: s, size: size, radius: 28),
        ),
      ),
    );
  }

  Widget _titleRow(Song s, ColorScheme scheme) {
    final fav = ctl.isFavorite(s);
    return Row(
      children: [
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Column(
              key: ValueKey(s.key),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurface, fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: -0.4, height: 1.2),
                ),
                const SizedBox(height: 4),
                Text(
                  s.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15, letterSpacing: 0.1),
                ),
              ],
            ),
          ),
        ),
        _QuietIcon(
          icon: fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          label: fav ? 'Remove from favorites' : 'Add to favorites',
          size: 22,
          dim: !fav,
          color: fav ? scheme.primary : null,
          onTap: () {
            HapticFeedback.selectionClick();
            ctl.toggleFavorite(s);
          },
        ),
      ],
    );
  }

  Widget _controls(BuildContext context, ColorScheme scheme) {
    Widget toggle(IconData icon, String label, bool on, VoidCallback onTap) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _QuietIcon(
            icon: icon,
            label: label,
            size: 20,
            dim: !on,
            color: on ? scheme.primary : null,
            onTap: () {
              HapticFeedback.selectionClick();
              onTap();
            },
          ),
          AnimatedOpacity(
            opacity: on ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: Container(width: 4, height: 4, decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle)),
          ),
        ],
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        toggle(Icons.shuffle_rounded, ctl.shuffle ? 'Shuffle on' : 'Shuffle off', ctl.shuffle, ctl.toggleShuffle),
        _QuietIcon(icon: Icons.skip_previous_rounded, label: 'Previous song', size: 34, box: 56, onTap: () {
          HapticFeedback.lightImpact();
          ctl.previous();
        }),
        _AudioPlayButton(playing: ctl.playing, onTap: () {
          HapticFeedback.mediumImpact();
          ctl.toggle();
        }),
        _QuietIcon(icon: Icons.skip_next_rounded, label: 'Next song', size: 34, box: 56, onTap: () {
          HapticFeedback.lightImpact();
          ctl.next();
        }),
        toggle(
          ctl.repeat == AudioRepeat.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
          'Repeat: ${ctl.repeat.name}',
          ctl.repeat != AudioRepeat.off,
          ctl.cycleRepeat,
        ),
      ],
    );
  }

  /// Quiet "Up next" line; opens the queue.
  Widget _upNext(BuildContext context, ColorScheme scheme) {
    final i = ctl.index + 1;
    final next = i >= 0 && i < ctl.queue.length ? ctl.queue[i] : null;
    return TextButton.icon(
      style: TextButton.styleFrom(
        foregroundColor: scheme.onSurfaceVariant,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      ),
      onPressed: () => _queue(context),
      icon: const Icon(Icons.queue_music_rounded, size: 18),
      label: Text(
        next == null ? 'Queue' : 'Up next · ${next.title}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _menu(BuildContext context, Song s, ColorScheme scheme) {
    final itemStyle = TextStyle(color: scheme.onSurface, fontSize: 14);
    PopupMenuItem<String> item(String value, String label, IconData icon, {bool checked = false}) => PopupMenuItem<String>(
          value: value,
          height: 42,
          child: Row(
            children: [
              Icon(icon, size: 19, color: scheme.onSurfaceVariant),
              const SizedBox(width: 14),
              Expanded(child: Text(label, style: itemStyle)),
              if (checked) Icon(Icons.check_rounded, size: 17, color: scheme.primary),
            ],
          ),
        );
    PopupMenuItem<String> header(String t) => PopupMenuItem<String>(
          enabled: false,
          height: 30,
          child: Text(t.toUpperCase(), style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 10.5, fontWeight: FontWeight.w600, letterSpacing: 0.9)),
        );
    String rate(double v) => v == v.roundToDouble() ? '${v.toStringAsFixed(0)}×' : '$v×';
    return PopupMenuButton<String>(
      tooltip: 'More',
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 280),
      icon: Icon(Icons.more_horiz_rounded, color: scheme.onSurface),
      onSelected: (v) {
        if (v == 'queue') _queue(context);
        if (v == 'send') sendSong(context, s);
        if (v == 'stop') {
          ctl.close();
          Navigator.pop(context);
        }
        if (v.startsWith('speed:')) ctl.setSpeed(double.parse(v.substring(6)));
        if (v.startsWith('sleep:')) {
          final m = int.parse(v.substring(6));
          ctl.setSleep(m == 0 ? null : Duration(minutes: m));
        }
      },
      itemBuilder: (_) => [
        item('queue', 'Queue', Icons.queue_music_rounded),
        item('send', 'Send this song', Icons.send_outlined),
        const PopupMenuDivider(height: 9),
        header('Speed · ${rate(ctl.speed)}'),
        for (final v in const [0.75, 1.0, 1.25, 1.5, 2.0])
          item('speed:$v', rate(v), Icons.speed_rounded, checked: (ctl.speed - v).abs() < 0.01),
        const PopupMenuDivider(height: 9),
        header(ctl.sleepAt != null ? 'Sleep timer · on' : 'Sleep timer'),
        for (final m in const [15, 30, 45, 60])
          item('sleep:$m', m == 60 ? '1 hour' : '$m minutes', Icons.bedtime_outlined),
        if (ctl.sleepAt != null) item('sleep:0', 'Turn off timer', Icons.timer_off_outlined),
        const PopupMenuDivider(height: 9),
        item('stop', 'Stop and close', Icons.stop_circle_outlined),
      ],
    );
  }

  void _queue(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: scheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      builder: (ctx) => Theme(
        data: Theme.of(context),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (ctx, scroll) => ListenableBuilder(
            listenable: ctl,
            builder: (ctx, _) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 16, 8),
                  child: Row(
                    children: [
                      Text('Up next', style: TextStyle(color: scheme.onSurface, fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -0.2)),
                      const SizedBox(width: 8),
                      Text('${ctl.queue.length} songs', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                    ],
                  ),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    scrollController: scroll,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    itemCount: ctl.queue.length,
                    onReorder: ctl.move,
                    itemBuilder: (ctx, i) {
                      final s = ctl.queue[i];
                      final cur = i == ctl.index;
                      return Padding(
                        key: ValueKey('q-$i-${s.key}'),
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Material(
                          color: cur ? scheme.primaryContainer.withValues(alpha: 0.55) : Colors.transparent,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          clipBehavior: Clip.antiAlias,
                          child: ListTile(
                            contentPadding: const EdgeInsets.fromLTRB(10, 0, 4, 0),
                            leading: AlbumArt(song: s, size: 42, radius: 10),
                            title: Text(
                              s.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: cur ? scheme.onPrimaryContainer : scheme.onSurface,
                                fontWeight: cur ? FontWeight.w600 : FontWeight.w500,
                                fontSize: 14.5,
                              ),
                            ),
                            subtitle: Text(
                              s.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: cur ? scheme.onPrimaryContainer.withValues(alpha: 0.75) : scheme.onSurfaceVariant, fontSize: 12.5),
                            ),
                            onTap: () => ctl.playQueue(ctl.queue, i),
                            trailing: cur
                                ? Padding(
                                    padding: const EdgeInsets.only(right: 12),
                                    child: Icon(Icons.graphic_eq_rounded, color: scheme.primary, size: 20),
                                  )
                                : Padding(
                                    padding: const EdgeInsets.only(right: 28),
                                    child: _QuietIcon(icon: Icons.close_rounded, label: 'Remove from queue', size: 18, dim: true, onTap: () => ctl.removeAt(i)),
                                  ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Centred see-through play/pause that follows the theme.
class _AudioPlayButton extends StatefulWidget {
  const _AudioPlayButton({required this.playing, required this.onTap});
  final bool playing;
  final VoidCallback onTap;

  @override
  State<_AudioPlayButton> createState() => _AudioPlayButtonState();
}

class _AudioPlayButtonState extends State<_AudioPlayButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const s = 76.0;
    return Semantics(
      button: true,
      label: widget.playing ? 'Pause' : 'Play',
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: LiquidGlassScope.of(context)
                ? (_hover && !_down ? 1.04 : 1.0)
                : (_down ? 0.92 : (_hover ? 1.04 : 1.0)),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: _face(scheme, s),
          ),
        ),
      ),
    );
  }

  Widget _face(ColorScheme scheme, double s) {
    final icon = AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      transitionBuilder: (c, a) => FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween(begin: 0.8, end: 1.0).animate(a), child: c),
      ),
      child: Icon(
        widget.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        key: ValueKey(widget.playing),
        size: 38,
        color: scheme.onSurface,
      ),
    );
    if (LiquidGlassScope.of(context)) {
      return LiquidSquash(
        pressed: _down,
        child: IosGlassPlate(
          dark: scheme.brightness == Brightness.dark,
          shadow: true,
          child: SizedBox(width: s, height: s, child: icon),
        ),
      );
    }
    return ClipOval(
      child: BackdropFilter(
        filter: GlassTokens.blur(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: s,
          height: s,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: scheme.onSurface.withValues(alpha: _hover ? 0.14 : 0.09),
            border: Border.all(color: scheme.onSurface.withValues(alpha: 0.14), width: 0.8),
          ),
          child: icon,
        ),
      ),
    );
  }
}

/// Thin, theme-aware seek bar with times; thickens on hover or drag.
class _AudioSeek extends StatefulWidget {
  const _AudioSeek({required this.ctl, required this.song});
  final AudioController ctl;
  final Song song;

  @override
  State<_AudioSeek> createState() => _AudioSeekState();
}

class _AudioSeekState extends State<_AudioSeek> {
  double? _drag;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<Duration>(
      valueListenable: widget.ctl.position,
      builder: (context, pos, _) {
        final total = widget.ctl.duration.inMilliseconds > 0 ? widget.ctl.duration : Duration(milliseconds: widget.song.durationMs);
        final ms = total.inMilliseconds;
        final f = _drag ?? (ms > 0 ? (pos.inMilliseconds / ms).clamp(0.0, 1.0) : 0.0);
        final shown = _drag == null ? pos : Duration(milliseconds: (ms * f).round());
        final active = _drag != null || _hover;
        final timeStyle = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12, fontWeight: FontWeight.w500, fontFeatures: _tabularFigures);
        return Semantics(
          slider: true,
          label: 'Seek bar, ${_fmt(shown)} of ${_fmt(total)}',
          child: Column(
            children: [
              LayoutBuilder(
                builder: (context, c) {
                  final w = c.maxWidth;
                  double x(double dx) => (dx / w).clamp(0.0, 1.0);
                  void seekTo(double fx) {
                    if (ms > 0) widget.ctl.seek(Duration(milliseconds: (ms * fx).round()));
                  }

                  return MouseRegion(
                    cursor: SystemMouseCursors.click,
                    onEnter: (_) => setState(() => _hover = true),
                    onExit: (_) => setState(() => _hover = false),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (d) => seekTo(x(d.localPosition.dx)),
                      onHorizontalDragStart: (d) => setState(() => _drag = x(d.localPosition.dx)),
                      onHorizontalDragUpdate: (d) => setState(() => _drag = x(d.localPosition.dx)),
                      onHorizontalDragEnd: (_) {
                        final fx = _drag ?? 0;
                        setState(() => _drag = null);
                        seekTo(fx);
                      },
                      onHorizontalDragCancel: () => setState(() => _drag = null),
                      child: SizedBox(
                        height: 28,
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(end: active ? 1 : 0),
                          duration: const Duration(milliseconds: 160),
                          builder: (context, t, _) => CustomPaint(
                            size: Size(w, 28),
                            painter: _AudioSeekPainter(
                              played: f,
                              t: t,
                              track: scheme.onSurface.withValues(alpha: 0.14),
                              fill: scheme.onSurface,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(shown), style: timeStyle),
                  Text(_fmt(total), style: timeStyle),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AudioSeekPainter extends CustomPainter {
  _AudioSeekPainter({required this.played, required this.t, required this.track, required this.fill});
  final double played;
  final double t;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final h = 3.0 + 2.0 * t;
    final y = size.height / 2;
    final r = Radius.circular(h);
    canvas.drawRRect(RRect.fromLTRBR(0, y - h / 2, size.width, y + h / 2, r), Paint()..color = track);
    final pw = size.width * played.clamp(0.0, 1.0);
    canvas.drawRRect(RRect.fromLTRBR(0, y - h / 2, pw, y + h / 2, r), Paint()..color = fill);
    final thumb = 3.0 + 4.0 * t;
    canvas.drawCircle(Offset(pw, y), thumb, Paint()..color = fill);
  }

  @override
  bool shouldRepaint(_AudioSeekPainter o) => o.played != played || o.t != t || o.track != track || o.fill != fill;
}
