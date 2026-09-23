import 'dart:io';

import 'package:flutter/services.dart';

class DeviceVideo {
  const DeviceVideo({
    required this.id,
    required this.title,
    this.path,
    this.uri,
    this.durationMs = 0,
    this.size = 0,
    this.addedAt = 0,
  });

  final String id;
  final String title;
  final String? path;
  final String? uri;
  final int durationMs;
  final int size;
  final int addedAt;

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
    );
  }
}

class DeviceMediaService {
  static const _channel = MethodChannel('socialsave/media');

  Future<List<DeviceVideo>> listVideos() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listVideos');
      return (raw ?? [])
          .whereType<Map<dynamic, dynamic>>()
          .map(DeviceVideo.fromMap)
          .where((video) {
            final path = video.path ?? '';
            return !path.contains('${Platform.pathSeparator}vault${Platform.pathSeparator}') &&
                !path.contains('/vault/');
          })
          .toList();
    } catch (_) {
      return [];
    }
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
