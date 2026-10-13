import 'dart:io';

import 'package:flutter/services.dart';
import 'package:social_save/core/platform/desktop_support.dart';

class DeviceVideo {
  const DeviceVideo({
    required this.id,
    required this.title,
    this.path,
    this.uri,
    this.durationMs = 0,
    this.size = 0,
    this.addedAt = 0,
    this.folder,
  });

  final String id;
  final String title;
  final String? path;
  final String? uri;
  final int durationMs;
  final int size;
  final int addedAt;

  /// Containing folder. Set on Windows only.
  final String? folder;

  factory DeviceVideo.fromMap(Map<dynamic, dynamic> map) {
    return DeviceVideo(
      id: '${map['id']}',
      title: (map['title'] as String?)?.trim().isNotEmpty == true
          ? map['title'] as String
          : 'Video',
      path: map['path'] as String?,
      uri: map['uri'] as String?,
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
      size: (map['size'] as num?)?.toInt() ?? 0,
      addedAt: (map['addedAt'] as num?)?.toInt() ?? 0,
      folder: map['folder'] as String?,
    );
  }
}

class DeviceMediaService {
  static const _channel = MethodChannel('socialsave/media');

  Future<List<DeviceVideo>> listVideos() async {
    try {
      final raw = DesktopSupport.isWindows
          ? await DesktopSupport.listVideos()
          : await _channel.invokeMethod<List<dynamic>>('listVideos');
      return _fromRaw(raw);
    } catch (_) {
      return [];
    }
  }

  List<DeviceVideo> _fromRaw(List<dynamic>? raw) {
    return (raw ?? [])
        .whereType<Map<dynamic, dynamic>>()
        .map(DeviceVideo.fromMap)
        .where((video) {
          final path = video.path ?? '';
          return !path.contains('${Platform.pathSeparator}vault${Platform.pathSeparator}') &&
              !path.contains('/vault/');
        })
        .toList();
  }

  /// Windows only: a fresh scan of the PC's video folders, emitting the
  /// list so far after each folder.
  Stream<List<DeviceVideo>> scanWindows() {
    return DesktopSupport.scanVideos().map(_fromRaw);
  }

  /// Windows only: the last finished scan, or null.
  List<DeviceVideo>? get cachedWindows {
    final cached = DesktopSupport.cachedVideos;
    return cached == null ? null : _fromRaw(cached);
  }

  Future<String?> resolvePlayablePath(DeviceVideo video) async {
    final path = video.path;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return path;
    }
    try {
      return await _channel.invokeMethod<String>('copyVideo', {
        'id': video.id,
        'path': video.path,
        'uri': video.uri,
      });
    } catch (_) {
      return null;
    }
  }

  Future<bool> renamePublic(DeviceVideo video, String name) async {
    if (DesktopSupport.isWindows) {
      final path = video.path;
      return path != null && await DesktopSupport.rename(path, name);
    }
    try {
      return await _channel.invokeMethod<bool>('renamePublicVideo', {
            'id': video.id,
            'path': video.path,
            'uri': video.uri,
            'name': name,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> deletePublic(DeviceVideo video) async {
    if (DesktopSupport.isWindows) {
      final path = video.path;
      return path != null && await DesktopSupport.delete(path);
    }
    if (await deleteMany([video]) > 0) return true;
    try {
      return await _channel.invokeMethod<bool>('deletePublicVideo', {
            'id': video.id,
            'path': video.path,
            'uri': video.uri,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Deletes several videos at once. Windows: Recycle Bin. Android: the
  /// file, or MediaStore (the system asks once for files the app didn't
  /// create). Returns how many were deleted.
  Future<int> deleteMany(List<DeviceVideo> videos) async {
    if (videos.isEmpty) return 0;
    if (DesktopSupport.isWindows) {
      final gone = await DesktopSupport.recycle([for (final v in videos) if (v.path != null) v.path!]);
      return gone.length;
    }
    try {
      return await _channel.invokeMethod<int>('deleteMedia', {
            'items': [for (final v in videos) {'id': v.id, 'path': v.path, 'uri': v.uri}],
          }) ??
          0;
    } catch (_) {
      return 0;
    }
  }

  /// Deletes files/folders by path (Received items). Folders are removed
  /// with everything inside.
  static Future<int> deletePaths(List<String> paths) async {
    if (paths.isEmpty) return 0;
    if (DesktopSupport.isWindows) return (await DesktopSupport.recycle(paths)).length;
    var n = 0;
    final files = <String>[];
    for (final path in paths) {
      final dir = Directory(path);
      if (dir.existsSync()) {
        final inside = dir.listSync(recursive: true).whereType<File>().map((f) => f.path).toList();
        try {
          await dir.delete(recursive: true);
          n++;
          for (final f in inside) {
            try {
              await _channel.invokeMethod<void>('scanFile', {'path': f});
            } catch (_) {}
          }
        } catch (_) {}
      } else {
        files.add(path);
      }
    }
    if (files.isNotEmpty) {
      try {
        n += await _channel.invokeMethod<int>('deleteMedia', {
              'items': [for (final f in files) {'id': null, 'path': f, 'uri': null}],
            }) ??
            0;
      } catch (_) {}
    }
    return n;
  }

  Future<void> setSecure(bool secure) async {
    try {
      await _channel.invokeMethod('setSecure', {'secure': secure});
    } catch (_) {}
  }

  Future<String?> videoThumbnail({
    String? id,
    String? path,
    String? uri,
  }) async {
    if (DesktopSupport.isWindows) {
      return path == null ? null : DesktopSupport.thumbnail(path);
    }
    try {
      return await _channel.invokeMethod<String>('videoThumbnail', {
        'id': id,
        'path': path,
        'uri': uri,
      });
    } catch (_) {
      return null;
    }
  }
}
