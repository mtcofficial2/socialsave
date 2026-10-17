import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/platform/media_events.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/library/share_session.dart';
import 'package:social_save/core/platform/disk_space_stub.dart'
    if (dart.library.ffi) 'package:social_save/core/platform/disk_space_ffi.dart';

/// Space on the drive or phone storage that holds the downloads.
class DeviceSpace {
  const DeviceSpace(this.free, this.total);
  final int free;
  final int total;
}

/// Free / total bytes of the phone's shared storage or the PC's Documents drive.
Future<DeviceSpace?> readDeviceSpace() async {
  if (kIsWeb) return null;
  try {
    if (Plat.isAndroid) {
      final m = await MediaEvents.channel.invokeMapMethod<String, dynamic>('storageStats');
      if (m == null) return null;
      return DeviceSpace((m['free'] as num).toInt(), (m['total'] as num).toInt());
    }
    if (Plat.isWindows) {
      final home = Platform.environment['USERPROFILE'] ?? 'C:\\';
      final r = windowsDiskSpace(home);
      if (r == null) return null;
      return DeviceSpace(r.$1, r.$2);
    }
  } catch (_) {}
  return null;
}

class _Usage {
  const _Usage({this.videos = 0, this.videoBytes = 0, this.cacheBytes = 0, this.space});
  final int videos;
  final int videoBytes;
  final int cacheBytes;
  final DeviceSpace? space;
}

/// Settings: how much space SocialSave uses, with a safe cache clean-up.
class StorageSection extends ConsumerStatefulWidget {
  const StorageSection({super.key});

  @override
  ConsumerState<StorageSection> createState() => _StorageSectionState();
}

class _StorageSectionState extends ConsumerState<StorageSection> {
  late Future<_Usage> _usage = _load();
  bool _clearing = false;

  Future<_Usage> _load() async {
    var videos = 0;
    var bytes = 0;
    try {
      final records = await ref.read(downloadsRepositoryProvider).getAll();
      for (final r in records) {
        if (r.status.name != 'completed') continue;
        var size = r.fileSize ?? 0;
        final path = r.localPath;
        if (path != null && !path.startsWith('content://')) {
          try {
            final f = File(path);
            if (!f.existsSync()) continue;
            size = f.lengthSync();
          } catch (_) {}
        }
        videos++;
        bytes += size;
      }
    } catch (_) {}
    var cache = 0;
    try {
      cache = await ref.read(downloadPathServiceProvider).cacheSizeBytes();
    } catch (_) {}
    return _Usage(videos: videos, videoBytes: bytes, cacheBytes: cache, space: await readDeviceSpace());
  }

  Future<void> _clear() async {
    setState(() => _clearing = true);
    try {
      await ref.read(downloadPathServiceProvider).clearCache(keepTransfers: ShareSession.active);
      await ref.read(thumbnailCacheManagerProvider).emptyCache();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _clearing = false;
      _usage = _load();
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Cache cleared')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<_Usage>(
      future: _usage,
      builder: (context, snap) {
        final u = snap.data;
        final space = u?.space;
        final used = space == null ? 0 : space.total - space.free;
        final fraction = space == null || space.total <= 0 ? 0.0 : used / space.total;
        final mine = space == null || space.total <= 0 ? 0.0 : (u!.videoBytes / space.total).clamp(0.0, fraction);
        return Column(
          key: const ValueKey('storage-section'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.pie_chart_outline_rounded, color: scheme.onSurfaceVariant),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Storage', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                      const SizedBox(height: 2),
                      Text(
                        space == null
                            ? (u == null ? 'Measuring…' : 'Space used by SocialSave')
                            : '${_bytes(space.free)} free of ${_bytes(space.total)}',
                        style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (space != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  height: 10,
                  child: Stack(
                    children: [
                      Container(color: scheme.surfaceContainerHighest),
                      FractionallySizedBox(
                        widthFactor: fraction.clamp(0.0, 1.0),
                        child: Container(color: scheme.primary.withValues(alpha: 0.35)),
                      ),
                      FractionallySizedBox(
                        widthFactor: mine,
                        child: Container(color: scheme.primary),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            _line(context, scheme.primary, 'Saved videos',
                u == null ? '…' : '${u.videos} · ${_bytes(u.videoBytes)}'),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _line(context, scheme.primary.withValues(alpha: 0.35), 'Thumbnails and temporary files',
                      u == null ? '…' : _bytes(u.cacheBytes)),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  key: const ValueKey('storage-clear-cache'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(72, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: _clearing ? null : _clear,
                  child: Text(_clearing ? 'Clearing…' : 'Clear'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _line(BuildContext context, Color dot, String label, String value) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))),
        Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

String _bytes(int b) {
  const k = 1024;
  if (b >= k * k * k) return '${(b / (k * k * k)).toStringAsFixed(1)} GB';
  if (b >= k * k) return '${(b / (k * k)).toStringAsFixed(1)} MB';
  if (b >= k) return '${(b / k).toStringAsFixed(0)} KB';
  return '$b B';
}
