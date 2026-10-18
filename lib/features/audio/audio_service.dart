import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/platform/media_events.dart';
import 'package:social_save/core/platform/phone_body.dart';
import 'package:social_save/core/platform/plat.dart';

class Song {
  const Song({
    required this.key,
    required this.title,
    required this.artist,
    required this.album,
    required this.folder,
    required this.durationMs,
    this.path,
    this.uri,
    this.id,
    this.addedAt = 0,
  });

  final String key;
  final String title;
  final String artist;
  final String album;
  final String folder;
  final int durationMs;
  final String? path;
  final String? uri;
  final String? id;
  final int addedAt;

  String get source => path ?? uri ?? '';
}

enum SongSort { recent, title, artist, duration }

enum AudioRepeat { off, all, one }

const _audioExt = {'mp3', 'm4a', 'aac', 'wav', 'flac', 'ogg', 'opus', 'wma', 'amr', 'mka'};

/// Every audio file on the device: Android MediaStore, or the Music folder
/// (plus chosen folders) on Windows.
class AudioLibrary extends ChangeNotifier {
  AudioLibrary._();
  static final AudioLibrary instance = AudioLibrary._();

  List<Song> songs = const [];
  bool loading = false;
  bool denied = false;
  bool loaded = false;
  String error = '';

  Future<List<String>> extraFolders() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList('socialsave_audio_folders') ?? const [];
  }

  Future<void> addFolder(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final l = prefs.getStringList('socialsave_audio_folders') ?? <String>[];
    if (!l.contains(path)) l.add(path);
    await prefs.setStringList('socialsave_audio_folders', l);
    await load(force: true);
  }

  Future<bool> askPermission() async {
    if (!Plat.isAndroid) return true;
    try {
      if ((await Permission.audio.request()).isGranted) return true;
      if ((await Permission.storage.request()).isGranted) return true;
    } catch (_) {}
    return false;
  }

  Future<void> load({bool force = false}) async {
    if (loading || (loaded && !force)) return;
    loading = true;
    error = '';
    notifyListeners();
    try {
      if (Plat.isAndroid) {
        final ok = await askPermission();
        denied = !ok;
        songs = ok ? await _loadAndroid() : const [];
      } else if (Plat.isWindows) {
        denied = false;
        songs = await _loadWindows();
      } else {
        songs = const [];
      }
      loaded = true;
    } catch (e) {
      error = 'Could not read your music ($e).';
    }
    loading = false;
    notifyListeners();
  }

  String _clean(String? v, String fallback) {
    final s = (v ?? '').trim();
    if (s.isEmpty || s == '<unknown>') return fallback;
    return s;
  }

  Future<List<Song>> _loadAndroid() async {
    final out = <Song>[];
    var offset = 0;
    while (true) {
      final raw = await MediaEvents.channel.invokeMethod<Map<Object?, Object?>>('queryMedia', {
        'kind': 'audio',
        'offset': offset,
        'limit': 500,
      });
      final items = (raw?['items'] as List?) ?? const [];
      final total = (raw?['total'] as num?)?.toInt() ?? 0;
      for (final it in items.whereType<Map<Object?, Object?>>()) {
        final path = it['path'] as String?;
        final name = (it['name'] as String?) ?? p.basename(path ?? 'audio');
        final dur = (it['durationMs'] as num?)?.toInt() ?? 0;
        final mime = '${it['mime'] ?? ''}';
        if (mime.isNotEmpty && !mime.startsWith('audio') && mime != 'application/ogg') continue;
        if (dur > 0 && dur < 5000) continue; // skip ringtones and clicks
        if (path != null && (path.contains('/vault/') || path.contains('/files/vault'))) continue;
        final folder = path != null ? p.basename(p.dirname(path)) : _clean(it['bucket'] as String?, 'Music');
        out.add(Song(
          key: 'a:${it['id']}',
          id: '${it['id']}',
          uri: it['uri'] as String?,
          path: path,
          title: _clean(it['title'] as String?, p.basenameWithoutExtension(name)),
          artist: _clean(it['artist'] as String?, 'Unknown artist'),
          album: _clean(it['album'] as String?, folder),
          folder: folder,
          durationMs: dur,
          addedAt: (it['addedAt'] as num?)?.toInt() ?? 0,
        ));
      }
      offset += items.length;
      if (items.isEmpty || offset >= total) break;
    }
    return out;
  }

  Future<List<Song>> _loadWindows() async {
    final home = Platform.environment['USERPROFILE'] ?? '';
    final roots = <String>[if (home.isNotEmpty) p.join(home, 'Music'), ...await extraFolders()];
    final out = <Song>[];
    final seen = <String>{};
    for (final root in roots) {
      final dir = Directory(root);
      if (!await dir.exists()) continue;
      try {
        await for (final e in dir.list(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          final ext = p.extension(e.path).replaceFirst('.', '').toLowerCase();
          if (!_audioExt.contains(ext) || !seen.add(e.path)) continue;
          final base = p.basenameWithoutExtension(e.path);
          var artist = 'Unknown artist';
          var title = base;
          final dash = base.indexOf(' - ');
          if (dash > 0) {
            artist = base.substring(0, dash).trim();
            title = base.substring(dash + 3).trim();
          }
          final folder = p.basename(p.dirname(e.path));
          int added = 0;
          try {
            added = e.statSync().modified.millisecondsSinceEpoch ~/ 1000;
          } catch (_) {}
          out.add(Song(key: 'w:${e.path}', path: e.path, title: title, artist: artist, album: folder, folder: folder, durationMs: 0, addedAt: added));
          if (out.length > 30000) break;
        }
      } catch (_) {}
    }
    return out;
  }

  final Map<String, Future<String?>> _art = {};

  /// Album art as a cached image file, or null.
  Future<String?> artFor(Song s) {
    if (!Plat.isAndroid || s.id == null) return Future.value(null);
    return _art.putIfAbsent(s.key, () async {
      try {
        return await MediaEvents.channel.invokeMethod<String>('videoThumbnail', {'id': 'audio_${s.id}', 'uri': s.uri, 'path': null});
      } catch (_) {
        return null;
      }
    });
  }

  List<Song> sorted(List<Song> list, SongSort sort) {
    final l = [...list];
    switch (sort) {
      case SongSort.recent:
        l.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      case SongSort.title:
        l.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case SongSort.artist:
        l.sort((a, b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()));
      case SongSort.duration:
        l.sort((a, b) => b.durationMs.compareTo(a.durationMs));
    }
    return l;
  }
}

/// The one audio player: own queue on top of a media_kit player, so shuffle,
/// repeat, reorder and resume behave the same on Android and Windows.
class AudioController extends ChangeNotifier {
  AudioController._();
  static final AudioController instance = AudioController._();

  Player? _player;
  final List<StreamSubscription<dynamic>> _subs = [];
  StreamSubscription<PhoneAction>? _actionSub;

  List<Song> queue = [];
  int index = -1;
  bool shuffle = false;
  AudioRepeat repeat = AudioRepeat.off;
  double speed = 1.0;
  bool playing = false;
  Duration duration = Duration.zero;
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  Set<String> favorites = {};
  Map<String, List<String>> playlists = {};
  DateTime? sleepAt;
  Timer? _sleep;
  bool _restored = false;
  bool restoreSession = false;
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);
  final _played = <int>{};

  Song? get current => index >= 0 && index < queue.length ? queue[index] : null;
  bool get hasQueue => current != null;

  Player _ensure() {
    var pl = _player;
    if (pl != null) return pl;
    pl = _player = Player();
    _subs.add(pl.stream.playing.listen((v) {
      playing = v;
      _phone();
      notifyListeners();
    }));
    _subs.add(pl.stream.position.listen((v) {
      position.value = v;
      if (DateTime.now().difference(_lastSave) > const Duration(seconds: 5)) {
        _lastSave = DateTime.now();
        unawaited(_persist());
        if (playing) _phone();
      }
    }));
    _subs.add(pl.stream.duration.listen((v) {
      duration = v;
      notifyListeners();
    }));
    _subs.add(pl.stream.completed.listen((done) {
      if (done) unawaited(_onCompleted());
    }));
    if (Plat.isAndroid) {
      _actionSub = PhoneBody.actions.stream.listen(_onPhoneAction);
      PhoneBody.ensure();
    }
    return pl;
  }

  void _onPhoneAction(PhoneAction a) {
    if (!hasQueue || !_audioActive) return;
    switch (a.name) {
      case 'toggle':
        unawaited(toggle());
      case 'play':
        unawaited(_ensure().play());
      case 'pause':
        unawaited(_ensure().pause());
      case 'next' || 'skipNext':
        unawaited(next());
      case 'prev' || 'skipPrev' || 'skipPrevious':
        unawaited(previous());
      case 'seek':
        unawaited(seek(position.value + Duration(seconds: a.delta)));
      case 'seekTo':
        unawaited(seek(Duration(milliseconds: a.delta)));
    }
  }

  /// False while a video player owns the media keys.
  static bool Function() videoPlayerOpen = () => false;
  bool get _audioActive => !videoPlayerOpen();

  Future<void> _onCompleted() async {
    if (repeat == AudioRepeat.one) {
      await _load(index);
      return;
    }
    await next(auto: true);
  }

  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    final prefs = await SharedPreferences.getInstance();
    favorites = (prefs.getStringList('socialsave_audio_fav') ?? const []).toSet();
    try {
      final pl = jsonDecode(prefs.getString('socialsave_audio_playlists') ?? '{}') as Map<String, dynamic>;
      playlists = {for (final e in pl.entries) e.key: [for (final k in (e.value as List)) '$k']};
    } catch (_) {}
    shuffle = prefs.getBool('socialsave_audio_shuffle') ?? false;
    repeat = AudioRepeat.values[(prefs.getInt('socialsave_audio_repeat') ?? 0).clamp(0, 2)];
    speed = prefs.getDouble('socialsave_audio_speed') ?? 1.0;
    restoreSession = prefs.getBool('socialsave_audio_restore') ?? false;
    try {
      final raw = restoreSession ? jsonDecode(prefs.getString('socialsave_audio_queue') ?? 'null') : null;
      if (raw is Map) {
        final q = <Song>[];
        for (final e in (raw['q'] as List)) {
          final m = e as Map<String, dynamic>;
          q.add(Song(
            key: '${m['k']}',
            title: '${m['t']}',
            artist: '${m['a']}',
            album: '${m['b']}',
            folder: '${m['f']}',
            durationMs: (m['d'] as num?)?.toInt() ?? 0,
            path: m['p'] as String?,
            uri: m['u'] as String?,
            id: m['i'] as String?,
          ));
        }
        final i = (raw['i'] as num?)?.toInt() ?? 0;
        if (q.isNotEmpty && i >= 0 && i < q.length) {
          queue = q;
          index = i;
          position.value = Duration(milliseconds: (raw['pos'] as num?)?.toInt() ?? 0);
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('socialsave_audio_fav', favorites.toList());
    await prefs.setString('socialsave_audio_playlists', jsonEncode(playlists));
    await prefs.setBool('socialsave_audio_shuffle', shuffle);
    await prefs.setInt('socialsave_audio_repeat', repeat.index);
    await prefs.setDouble('socialsave_audio_speed', speed);
    if (queue.isEmpty) return;
    await prefs.setString(
      'socialsave_audio_queue',
      jsonEncode({
        'i': index,
        'pos': position.value.inMilliseconds,
        'q': [
          for (final s in queue.take(2000))
            {'k': s.key, 't': s.title, 'a': s.artist, 'b': s.album, 'f': s.folder, 'd': s.durationMs, 'p': s.path, 'u': s.uri, 'i': s.id},
        ],
      }),
    );
  }

  void _phone() {
    if (!Plat.isAndroid) return;
    final s = current;
    unawaited(PhoneBody.setPlayback(
      active: s != null,
      playing: playing,
      title: s == null ? '' : '${s.title} · ${s.artist}',
      headset: true,
      volumeSeek: false,
      background: true,
      positionMs: position.value.inMilliseconds,
      durationMs: duration.inMilliseconds > 0 ? duration.inMilliseconds : (s?.durationMs ?? 0),
    ));
  }

  Future<void> playQueue(List<Song> songs, int start, {bool? shuffleOn}) async {
    if (songs.isEmpty) return;
    queue = [...songs];
    if (shuffleOn != null) shuffle = shuffleOn;
    _played.clear();
    var i = start.clamp(0, queue.length - 1);
    if (shuffle && shuffleOn == true) i = math.Random().nextInt(queue.length);
    await _load(i);
  }

  Future<void> _load(int i, {bool play = true, Duration? seekTo}) async {
    if (i < 0 || i >= queue.length) return;
    index = i;
    _played.add(i);
    final pl = _ensure();
    position.value = seekTo ?? Duration.zero;
    notifyListeners();
    try {
      await pl.open(Media(queue[i].source), play: play);
      await pl.setRate(speed);
      if (seekTo != null && seekTo > Duration.zero) await pl.seek(seekTo);
    } catch (_) {}
    _phone();
    unawaited(_persist());
  }

  /// Resume a restored queue when the user taps play.
  Future<void> toggle() async {
    if (!hasQueue) return;
    final pl = _player;
    if (pl == null || pl.state.playlist.medias.isEmpty) {
      await _load(index, seekTo: position.value);
      return;
    }
    await pl.playOrPause();
  }

  Future<void> next({bool auto = false}) async {
    if (queue.isEmpty) return;
    int n;
    if (shuffle && queue.length > 1) {
      final left = [for (var i = 0; i < queue.length; i++) if (!_played.contains(i)) i];
      if (left.isEmpty) {
        if (repeat == AudioRepeat.off && auto) {
          await _player?.pause();
          return;
        }
        _played.clear();
        _played.add(index);
        final all = [for (var i = 0; i < queue.length; i++) if (i != index) i];
        n = all[math.Random().nextInt(all.length)];
      } else {
        n = left[math.Random().nextInt(left.length)];
      }
    } else {
      n = index + 1;
      if (n >= queue.length) {
        if (repeat == AudioRepeat.all || !auto) {
          n = 0;
        } else {
          await _player?.pause();
          await _player?.seek(Duration.zero);
          return;
        }
      }
    }
    await _load(n);
  }

  Future<void> previous() async {
    if (queue.isEmpty) return;
    if (position.value > const Duration(seconds: 4)) {
      await seek(Duration.zero);
      return;
    }
    await _load(index > 0 ? index - 1 : queue.length - 1);
  }

  Future<void> seek(Duration d) async {
    position.value = d;
    await _player?.seek(d);
  }

  Future<void> setSpeed(double v) async {
    speed = v;
    await _player?.setRate(v);
    notifyListeners();
    unawaited(_persist());
  }

  Future<void> setRestoreSession(bool v) async {
    restoreSession = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('socialsave_audio_restore', v);
    if (!v) await prefs.remove('socialsave_audio_queue');
    notifyListeners();
  }

  /// Stops playback, clears the queue and the lock-screen session.
  Future<void> close() async {
    _sleep?.cancel();
    sleepAt = null;
    try {
      await _player?.stop();
    } catch (_) {}
    queue = [];
    index = -1;
    playing = false;
    duration = Duration.zero;
    position.value = Duration.zero;
    _played.clear();
    if (Plat.isAndroid) {
      await PhoneBody.setPlayback(active: false, playing: false, title: '', headset: true, volumeSeek: false, background: false);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('socialsave_audio_queue');
    notifyListeners();
  }

  void toggleShuffle() {
    shuffle = !shuffle;
    _played
      ..clear()
      ..add(index);
    notifyListeners();
    unawaited(_persist());
  }

  void cycleRepeat() {
    repeat = AudioRepeat.values[(repeat.index + 1) % 3];
    notifyListeners();
    unawaited(_persist());
  }

  void setSleep(Duration? d) {
    _sleep?.cancel();
    if (d == null) {
      sleepAt = null;
    } else {
      sleepAt = DateTime.now().add(d);
      _sleep = Timer(d, () async {
        await _player?.pause();
        sleepAt = null;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  void move(int from, int to) {
    if (from < 0 || from >= queue.length) return;
    final cur = current;
    final s = queue.removeAt(from);
    queue.insert(to > from ? to - 1 : to, s);
    index = cur == null ? 0 : queue.indexOf(cur);
    _played.clear();
    _played.add(index);
    notifyListeners();
    unawaited(_persist());
  }

  void removeAt(int i) {
    if (i < 0 || i >= queue.length || i == index) return;
    final cur = current;
    queue.removeAt(i);
    index = cur == null ? 0 : queue.indexOf(cur);
    _played.clear();
    _played.add(index);
    notifyListeners();
  }

  void playNext(Song s) {
    if (!hasQueue) {
      unawaited(playQueue([s], 0));
      return;
    }
    queue.insert(index + 1, s);
    _played.clear();
    _played.add(index);
    notifyListeners();
  }

  void addToQueue(Song s) {
    if (!hasQueue) {
      unawaited(playQueue([s], 0));
      return;
    }
    queue.add(s);
    notifyListeners();
  }

  bool isFavorite(Song s) => favorites.contains(s.key);

  void toggleFavorite(Song s) {
    if (!favorites.remove(s.key)) favorites.add(s.key);
    HapticFeedback.selectionClick();
    notifyListeners();
    unawaited(_persist());
  }

  void createPlaylist(String name) {
    if (name.trim().isEmpty) return;
    playlists.putIfAbsent(name.trim(), () => []);
    notifyListeners();
    unawaited(_persist());
  }

  void addToPlaylist(String name, Song s) {
    final l = playlists.putIfAbsent(name, () => []);
    if (!l.contains(s.key)) l.add(s.key);
    notifyListeners();
    unawaited(_persist());
  }

  void deletePlaylist(String name) {
    playlists.remove(name);
    notifyListeners();
    unawaited(_persist());
  }
}