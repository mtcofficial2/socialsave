import 'dart:io';
import 'package:social_save/core/platform/plat.dart';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:social_save/core/storage/download_path_service.dart';
import 'package:social_save/core/platform/desktop_support.dart';

/// One file inside a transfer, with its path relative to the bundle root.
class SendItem {
  SendItem(this.file, this.rel, this.size);
  final File file;
  final String rel;
  final int size;
}

/// Files (or a whole folder) to send in one go.
class SendBundle {
  SendBundle(this.label, this.items, {this.isFolder = false});

  final String label;
  final List<SendItem> items;
  final bool isFolder;

  int get total => items.fold(0, (a, b) => a + b.size);
  int get count => items.length;

  /// "Holiday · 12 files" style summary.
  String get summary => isFolder || count > 1 ? '$label · $count files' : label;

  static Future<SendBundle?> fromFiles(List<File> files) async {
    final items = <SendItem>[];
    final used = <String>{};
    for (final f in files) {
      if (!f.existsSync()) continue;
      var name = p.basename(f.path);
      var i = 1;
      while (!used.add(name.toLowerCase())) {
        name = '${p.basenameWithoutExtension(f.path)} ($i)${p.extension(f.path)}';
        i++;
      }
      items.add(SendItem(f, name, await f.length()));
    }
    if (items.isEmpty) return null;
    final label = items.length == 1 ? items.first.rel : '${items.length} files';
    return SendBundle(label, items);
  }

  static Future<SendBundle?> fromFolder(Directory dir) async {
    if (!dir.existsSync()) return null;
    final items = <SendItem>[];
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = p.relative(e.path, from: dir.path).replaceAll('\\', '/');
      items.add(SendItem(e, rel, await e.length()));
    }
    if (items.isEmpty) return null;
    items.sort((a, b) => a.rel.compareTo(b.rel));
    return SendBundle(p.basename(dir.path), items, isFolder: true);
  }
}

const _media = MethodChannel('socialsave/media');

/// System picker for any files (several allowed).
Future<SendBundle?> pickAnyFiles() async {
  if (Plat.isAndroid) {
    final paths = await _media.invokeListMethod<String>('pickSendFiles');
    if (paths == null || paths.isEmpty) return null;
    return SendBundle.fromFiles(paths.map(File.new).toList());
  }
  final picked = await openFiles();
  if (picked.isEmpty) return null;
  return SendBundle.fromFiles(picked.map((x) => File(x.path)).toList());
}

/// System picker for a folder; its whole tree is sent.
Future<SendBundle?> pickAnyFolder() async {
  if (Plat.isAndroid) {
    // The phone copies the chosen tree (Storage Access Framework) into the
    // app cache, so no broad storage permission is needed.
    final path = await _media.invokeMethod<String>('pickSendFolder');
    if (path == null || path.isEmpty) return null;
    return SendBundle.fromFolder(Directory(path));
  }
  final path = await getDirectoryPath();
  if (path == null) return null;
  return SendBundle.fromFolder(Directory(path));
}

const videoExtensions = {'.mp4', '.mkv', '.webm', '.mov', '.avi', '.m4v', '.3gp', '.mp3', '.m4a'};

bool isVideoName(String name) => videoExtensions.contains(p.extension(name).toLowerCase());

const _reserved = {
  'con', 'prn', 'aux', 'nul', 'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
  'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
};

/// One safe path segment: no separators, illegal Windows characters,
/// control characters, trailing dots/spaces or reserved names; max 120 chars.
String safeSegment(String raw) {
  var s = raw.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  s = s.replaceAll(RegExp(r'[. ]+$'), '');
  if (s.isEmpty || s == '.' || s == '..') s = '_';
  if (_reserved.contains(p.basenameWithoutExtension(s).toLowerCase())) s = '_$s';
  if (s.length > 120) {
    final ext = p.extension(s);
    s = s.substring(0, 120 - (ext.length > 20 ? 0 : ext.length)) + (ext.length > 20 ? '' : ext);
  }
  return s;
}

/// Turns a sender-supplied relative path into safe segments. Absolute
/// paths, drive letters and '..' can never escape the destination folder.
List<String> safeRelative(String raw) {
  final parts = raw
      .replaceAll('\\', '/')
      .split('/')
      .where((s) => s.isNotEmpty && s != '.' && s != '..')
      .map(safeSegment)
      .toList();
  if (parts.isEmpty) return ['file'];
  // Keep the whole path reasonably short (Windows MAX_PATH).
  while (parts.length > 1 && parts.join('/').length > 180) {
    parts.removeAt(0);
  }
  return parts.length > 24 ? parts.sublist(parts.length - 24) : parts;
}

/// Picks "<name>", "<name> (1)", "<name> (2)"… so nothing is overwritten.
String uniquePath(String path, {bool dir = false}) {
  bool taken(String x) => dir ? Directory(x).existsSync() || File(x).existsSync() : File(x).existsSync() || Directory(x).existsSync();
  if (!taken(path)) return path;
  final folder = p.dirname(path);
  final base = dir ? p.basename(path) : p.basenameWithoutExtension(path);
  final ext = dir ? '' : p.extension(path);
  for (var i = 1;; i++) {
    final c = p.join(folder, '$base ($i)$ext');
    if (!taken(c)) return c;
  }
}

/// Where received non-video files go:
/// Windows: Documents\SocialSave\Received; Android: Download/SocialSave/Received.
Future<Directory> receivedRoot() async {
  Directory base;
  if (DesktopSupport.isWindows) {
    base = Directory(p.join(Platform.environment['USERPROFILE'] ?? '.', 'Documents', 'SocialSave'));
  } else {
    base = await DownloadPathService().resolveDirectory(DownloadLocation.publicDownloads);
  }
  final dir = Directory(p.join(base.path, 'Received'));
  await dir.create(recursive: true);
  return dir;
}

/// A fresh folder for one incoming bundle (named after the folder or sender).
Future<Directory> newReceiveDir(String label) async {
  final root = await receivedRoot();
  final dir = Directory(uniquePath(p.join(root.path, safeSegment(label)), dir: true));
  await dir.create(recursive: true);
  return dir;
}

/// Destination for file [rel] inside [root], creating sub-folders.
Future<File> destInside(Directory root, String rel) async {
  final parts = safeRelative(rel);
  final path = uniquePath(p.joinAll([root.path, ...parts]));
  await Directory(p.dirname(path)).create(recursive: true);
  return File(path);
}

/// Make received media visible in the phone gallery / Files app.
Future<void> indexReceived(File f) async {
  if (!Plat.isAndroid) return;
  try {
    await _media.invokeMethod<void>('scanFile', {'path': f.path});
  } catch (_) {}
}

/// Open with the system's default app.
Future<bool> openWithSystem(String path) async {
  try {
    if (Plat.isWindows) {
      await Process.start('explorer.exe', [path], runInShell: false);
      return true;
    }
    if (Plat.isAndroid) {
      return await _media.invokeMethod<bool>('openFile', {'path': path}) ?? false;
    }
  } catch (_) {}
  return false;
}

/// Windows Explorer with the item selected.
Future<void> showInFolder(String path) async {
  if (!Plat.isWindows) return;
  try {
    await Process.start('explorer.exe', ['/select,', path]);
  } catch (_) {}
}
