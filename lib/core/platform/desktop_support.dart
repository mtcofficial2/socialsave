import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/platform/windows_video_scan.dart';
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

  /// `Downloads\SocialSave` (created if missing).
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
  static int _scanGeneration = 0;

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

  /// Scans the default folders and the user's added folders, one root at a
  /// time in a background isolate. Each event is the full list so far,
  /// newest first. The last event is the complete list.
  static Stream<List<Map<String, Object?>>> scanVideos() async* {
    final generation = ++_scanGeneration;
    final roots = <String>[
      ...await defaultFolders(),
      ...await extraFolders(),
    ];
    final seen = <String>{};
    final found = <Map<String, Object?>>[];
    for (final root in roots) {
      if (generation != _scanGeneration) return;
      if (!Directory(root).existsSync()) continue;
      List<Map<String, Object?>> batch;
      try {
        batch = await _scanRootInIsolate(root);
      } catch (_) {
        continue;
      }
      if (generation != _scanGeneration) return;
      for (final item in batch) {
        if (seen.add('${item['path']}'.toLowerCase())) found.add(item);
      }
      found.sort((a, b) => (b['addedAt'] as int).compareTo(a['addedAt'] as int));
      yield List.unmodifiable(found);
    }
    cachedVideos = List.unmodifiable(found);
    if (roots.isEmpty) yield const [];
  }

  /// Cached list if a scan already finished, otherwise a fresh scan.
  static Future<List<Map<String, Object?>>> listVideos() async {
    final cached = cachedVideos;
    if (cached != null) return cached;
    List<Map<String, Object?>> last = const [];
    await for (final batch in scanVideos()) {
      last = batch;
    }
    return last;
  }

  static void _updateCache(String oldPath, String? newPath) {
    final cached = cachedVideos;
    if (cached == null) return;
    final next = <Map<String, Object?>>[];
    for (final item in cached) {
      if ('${item['path']}'.toLowerCase() != oldPath.toLowerCase()) {
        next.add(item);
        continue;
      }
      if (newPath == null) continue;
      next.add({
        ...item,
        'id': newPath,
        'path': newPath,
        'title': p.basenameWithoutExtension(newPath),
      });
    }
    cachedVideos = List.unmodifiable(next);
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

  static Future<bool> delete(String path) async {
    try {
      final file = File(path);
      if (file.existsSync()) await file.delete();
      _updateCache(path, null);
      return true;
    } catch (_) {
      return false;
    }
  }
}

// Top-level so the isolate closures capture only their arguments.
Future<List<Map<String, Object?>>> _scanRootInIsolate(String root) =>
    Isolate.run(() => scanWindowsVideoRoot(root));

Future<String?> _thumbInIsolate(String path, String out) =>
    Isolate.run(() => windowsShellThumbnail(path, out, 320));
