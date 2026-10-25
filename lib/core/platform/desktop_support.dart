import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/platform/windows_video_scan_stub.dart'
    if (dart.library.ffi) 'package:social_save/core/platform/windows_video_scan.dart';
import 'package:social_save/core/storage/download_path_service.dart';
import 'package:url_launcher/url_launcher.dart';

/// Windows stand-ins for the Android-only parts of the app.
///
/// Android keeps using its native `socialsave/media` channel. These helpers
/// are only called when [isWindows] is true.
class DesktopSupport {
  const DesktopSupport._();

  static bool get isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// `Documents\SocialSave` (created if missing).
  static Future<Directory> saveFolder() {
    return DownloadPathService().resolveDirectory(DownloadLocation.publicDownloads);
  }

  /// Opens a file or folder with its default Windows app.
  static Future<bool> open(String path) async {
    try {
      final uri = FileSystemEntity.isDirectorySync(path)
          ? Uri.directory(path, windows: true)
          : Uri.file(path, windows: true);
      if (await launchUrl(uri)) return true;
    } catch (_) {}
    try {
      await Process.start('explorer.exe', [path]);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Opens File Explorer with the file selected.
  static Future<bool> revealInFolder(String path) async {
    try {
      if (File(path).existsSync()) {
        await Process.start('explorer.exe', ['/select,', path]);
      } else {
        await Process.start('explorer.exe', [p.dirname(path)]);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------
  // Library: every video on this PC (Windows only).

  static const _foldersKey = 'socialsave_windows_video_folders';

  /// Last full scan, kept for the life of the app.
  static List<Map<String, Object?>>? cachedVideos;

  /// True after a scan has finished in this session. A saved index can be
  /// shown before that, so search works while the folders are checked.
  static bool scanFinished = false;
  static int _scanGeneration = 0;
  static bool _indexLoaded = false;
  static Map<String, Object?> _savedDirs = {};
  static final Set<String> _gone = {};
  static File? _indexFile;

  static Future<List<String>> extraFolders() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_foldersKey) ?? const [];
  }

  static Future<void> setExtraFolders(List<String> folders) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_foldersKey, folders.toSet().toList());
  }

  static Future<List<String>> defaultFolders() =>
      Isolate.run(windowsDefaultVideoRoots);

  /// The last saved index, if this PC has been scanned before.
  static Future<List<Map<String, Object?>>?> savedVideos() async {
    await _loadIndex();
    final cached = cachedVideos;
    if (cached == null || cached.isEmpty) return null;
    return cached;
  }

  /// Scans the default folders and the user's added folders, one root at a
  /// time in a background isolate. When a saved index already exists, only
  /// the finished list is emitted so the library does not jump. Otherwise
  /// each event is the full list so far, newest first.
  static Stream<List<Map<String, Object?>>> scanVideos() async* {
    final generation = ++_scanGeneration;
    scanFinished = false;
    await _loadIndex();
    final roots = <String>[
      ...await defaultFolders(),
      ...await extraFolders(),
    ];
    final showPartials = cachedVideos == null || cachedVideos!.isEmpty;
    final seen = <String>{};
    final found = <Map<String, Object?>>[];
    final nextDirs = <String, Object?>{};
    for (final root in roots) {
      if (generation != _scanGeneration) return;
      if (!Directory(root).existsSync()) continue;
      ({List<Map<String, Object?>> videos, Map<String, Object?> dirs}) piece;
      try {
        piece = await _scanRootInIsolate(root, _dirsForRoot(root));
      } catch (_) {
        continue;
      }
      if (generation != _scanGeneration) return;
      nextDirs.addAll(piece.dirs);
      for (final item in piece.videos) {
        final path = '${item['path']}'.toLowerCase();
        if (path.isEmpty || _gone.contains(path) || !seen.add(path)) continue;
        found.add(item);
      }
      if (showPartials) {
        found.sort(_byAdded);
        yield List.unmodifiable(found);
      }
    }
    if (generation != _scanGeneration) return;
    found.sort(_byAdded);
    final done = List<Map<String, Object?>>.unmodifiable(found);
    cachedVideos = done;
    _savedDirs = nextDirs;
    await _storeIndex();
    if (generation != _scanGeneration) return;
    scanFinished = true;
    yield done;
  }

  /// Cached list if a scan already finished, otherwise a fresh scan.
  static Future<List<Map<String, Object?>>> listVideos() async {
    final cached = cachedVideos;
    if (cached != null && scanFinished) return cached;
    await _loadIndex();
    if (cachedVideos != null && scanFinished) return cachedVideos!;
    List<Map<String, Object?>> last = cachedVideos ?? const [];
    await for (final batch in scanVideos()) {
      last = batch;
    }
    return last;
  }

  static int _byAdded(Map<String, Object?> a, Map<String, Object?> b) {
    final left = a['addedAt'];
    final right = b['addedAt'];
    final av = left is num ? left.toInt() : 0;
    final bv = right is num ? right.toInt() : 0;
    return bv.compareTo(av);
  }

  static Map<String, Object?> _dirsForRoot(String root) {
    final prefix = root.toLowerCase();
    final out = <String, Object?>{};
    for (final entry in _savedDirs.entries) {
      final key = entry.key.toLowerCase();
      if (key == prefix || key.startsWith('$prefix\\') || key.startsWith('$prefix/')) {
        out[entry.key] = entry.value;
      }
    }
    return out;
  }

  static Future<File> _indexPath() async {
    final ready = _indexFile;
    if (ready != null) return ready;
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'socialsave_video_index.json'));
    _indexFile = file;
    return file;
  }

  static Future<void> _loadIndex() async {
    if (_indexLoaded) return;
    _indexLoaded = true;
    try {
      final file = await _indexPath();
      if (!file.existsSync()) return;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return;
      final dirs = data['dirs'];
      if (dirs is! Map) return;
      final parsed = <String, Object?>{};
      final videos = <Map<String, Object?>>[];
      for (final entry in dirs.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        parsed['${entry.key}'] = value;
        final files = value['v'];
        if (files is! List) continue;
        for (final raw in files) {
          if (raw is! Map) continue;
          final path = '${raw['path'] ?? ''}'.toLowerCase();
          if (path.isEmpty || _gone.contains(path)) continue;
          videos.add(Map<String, Object?>.from(raw.map((key, item) => MapEntry('$key', item))));
        }
      }
      _savedDirs = parsed;
      if (videos.isEmpty) return;
      videos.sort(_byAdded);
      cachedVideos ??= List.unmodifiable(videos);
    } catch (_) {}
  }

  static Future<void> _storeIndex() async {
    try {
      final file = await _indexPath();
      if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode({'dirs': _savedDirs}), flush: true);
      if (file.existsSync()) await file.delete();
      await tmp.rename(file.path);
    } catch (_) {}
  }

  static Future<void> _persistCacheEdit(String oldPath, String? newPath) async {
    try {
      await _loadIndex();
      final oldKey = oldPath.toLowerCase();
      var changed = false;
      for (final entry in _savedDirs.entries) {
        final dir = entry.value;
        if (dir is! Map) continue;
        final files = dir['v'];
        if (files is! List) continue;
        final next = <Object?>[];
        var edited = false;
        for (final raw in files) {
          if (raw is! Map) {
            next.add(raw);
            continue;
          }
          if ('${raw['path'] ?? ''}'.toLowerCase() != oldKey) {
            next.add(raw);
            continue;
          }
          edited = true;
          if (newPath == null) continue;
          next.add({
            ...Map<String, Object?>.from(raw.map((key, item) => MapEntry('$key', item))),
            'id': newPath,
            'path': newPath,
            'title': p.basenameWithoutExtension(newPath),
            'folder': p.dirname(newPath),
          });
        }
        if (!edited) continue;
        changed = true;
        dir['v'] = next;
        dir['m'] = '';
      }
      if (changed) await _storeIndex();
    } catch (_) {}
  }

  static void _updateCache(String oldPath, String? newPath) {
    final key = oldPath.toLowerCase();
    if (newPath == null) _gone.add(key);
    final cached = cachedVideos;
    if (cached != null) {
      final next = <Map<String, Object?>>[];
      for (final item in cached) {
        if ('${item['path']}'.toLowerCase() != key) {
          next.add(item);
          continue;
        }
        if (newPath == null) continue;
        next.add({
          ...item,
          'id': newPath,
          'path': newPath,
          'title': p.basenameWithoutExtension(newPath),
          'folder': p.dirname(newPath),
        });
      }
      cachedVideos = List.unmodifiable(next);
    }
    unawaited(_persistCacheEdit(oldPath, newPath));
  }

  // Thumbnails from the Windows shell, at most two at a time, cached on disk.
  static int _thumbsRunning = 0;
  static final _thumbQueue = <Completer<void>>[];
  static final _thumbMemo = <String, Future<String?>>{};

  static Future<String?> thumbnail(String path) {
    return _thumbMemo.putIfAbsent(path.toLowerCase(), () => _thumbnail(path));
  }

  static Future<String?> _thumbnail(String path) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    final stat = file.statSync();
    final key = md5
        .convert(utf8.encode('${path.toLowerCase()}|${stat.size}|${stat.modified.millisecondsSinceEpoch}'))
        .toString();
    final dir = Directory(p.join((await getTemporaryDirectory()).path, 'socialsave_thumbs'));
    final out = p.join(dir.path, '$key.bmp');
    if (File(out).existsSync()) return out;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    if (_thumbsRunning >= 2) {
      final wait = Completer<void>();
      _thumbQueue.add(wait);
      await wait.future;
    }
    _thumbsRunning++;
    try {
      return await _thumbInIsolate(path, out)
          .timeout(const Duration(seconds: 15), onTimeout: () => null);
    } catch (_) {
      return null;
    } finally {
      _thumbsRunning--;
      if (_thumbQueue.isNotEmpty) _thumbQueue.removeAt(0).complete();
    }
  }

  static Future<bool> rename(String path, String name) async {
    try {
      final file = File(path);
      if (!file.existsSync()) return false;
      final ext = p.extension(path);
      var cleaned = name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
      if (cleaned.isEmpty) return false;
      if (p.extension(cleaned).toLowerCase() != ext.toLowerCase()) {
        cleaned = '$cleaned$ext';
      }
      final target = p.join(p.dirname(path), cleaned);
      if (File(target).existsSync()) return false;
      await file.rename(target);
      _updateCache(path, target);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> delete(String path) async => (await recycle([path])).contains(path);

  /// Sends files or folders to the Windows Recycle Bin (undo-able), not a
  /// permanent delete. Returns the paths that are gone afterwards.
  static Future<List<String>> recycle(List<String> paths) async {
    paths = [for (final x in paths) if (File(x).existsSync() || Directory(x).existsSync()) x];
    if (paths.isEmpty) return const [];
    final gone = <String>[];
    try {
      final list = File(p.join(Directory.systemTemp.path, 'ss_recycle_${DateTime.now().microsecondsSinceEpoch}.txt'));
      await list.writeAsString(paths.join('\n'), encoding: utf8);
      const script = r'''
param($list)
Add-Type -AssemblyName Microsoft.VisualBasic
foreach ($p in [IO.File]::ReadAllLines($list, [Text.Encoding]::UTF8)) {
  if ([string]::IsNullOrWhiteSpace($p)) { continue }
  try {
    if ([IO.Directory]::Exists($p)) {
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p, 'OnlyErrorDialogs', 'SendToRecycleBin')
    } elseif ([IO.File]::Exists($p)) {
      [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin')
    }
  } catch { }
}
''';
      final ps1 = File('${list.path}.ps1');
      await ps1.writeAsString(script, encoding: utf8);
      await Process.run('powershell.exe', [
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', ps1.path, list.path,
      ]).timeout(const Duration(minutes: 5));
      for (final f in [list, ps1]) {
        try {
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
    for (final path in paths) {
      if (!File(path).existsSync() && !Directory(path).existsSync()) {
        gone.add(path);
        _updateCache(path, null);
      }
    }
    return gone;
  }
}

// Top-level so the isolate closures capture only their arguments.
Future<({List<Map<String, Object?>> videos, Map<String, Object?> dirs})> _scanRootInIsolate(
  String root,
  Map<String, Object?> remembered,
) =>
    Isolate.run(() => scanWindowsVideoRoot(root, remembered));

Future<String?> _thumbInIsolate(String path, String out) =>
    Isolate.run(() => windowsShellThumbnail(path, out, 320));
