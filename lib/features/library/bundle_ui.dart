import 'dart:async';
import 'package:social_save/core/platform/plat.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:social_save/features/library/bundle_transfer.dart';
import 'package:social_save/features/library/device_media.dart';
import 'package:social_save/features/library/nearby_service.dart';
import 'package:social_save/features/library/phone_handoff.dart';
import 'package:social_save/features/library/transfer_meter.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/routing/app_router.dart';

String sizeLabel(int bytes) {
  const kb = 1024, mb = 1024 * 1024, gb = 1024 * 1024 * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
  return '$bytes B';
}

/// "Files" / "Folder" picker, then where to send it.
Future<void> pickAndSendBundle(BuildContext context, {required bool folder}) async {
  final SendBundle? bundle;
  try {
    bundle = folder ? await pickAnyFolder() : await pickAnyFiles();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open the picker: $e')));
    }
    return;
  }
  if (bundle == null || !context.mounted) return;
  await chooseTargetAndSend(context, bundle);
}

/// Lets the user tap a nearby device or type a receiver's code.
Future<void> chooseTargetAndSend(BuildContext context, SendBundle bundle) async {
  NearbyService.ping();
  final code = TextEditingController();
  final target = await showDialog<Object>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Send to…'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${bundle.summary} · ${sizeLabel(bundle.total)}', maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            ValueListenableBuilder<List<NearbyDevice>>(
              valueListenable: NearbyService.devices,
              builder: (context, list, _) => list.isEmpty
                  ? Text('Looking for nearby phones and PCs…', style: Theme.of(context).textTheme.bodySmall)
                  : Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final d in list)
                          ActionChip(
                            avatar: Icon(
                              d.isCable ? Icons.cable_rounded : (d.isPc ? Icons.computer_rounded : Icons.smartphone_rounded),
                              size: 18,
                            ),
                            label: Text('${d.playerName} · ${d.name}'),
                            onPressed: () => Navigator.pop(context, d),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: code,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Or type the code shown on the receiver (Receive)',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, code.text), child: const Text('Send with code')),
      ],
    ),
  );
  if (target == null || !context.mounted) return;
  if (target is String && target.trim().isEmpty) return;
  await _sendWithProgress(context, bundle, target);
}

Future<void> _sendWithProgress(BuildContext context, SendBundle bundle, Object target) async {
  final name = target is NearbyDevice ? target.name : 'code ${target.toString().toUpperCase()}';
  final status = ValueNotifier<String>('Connecting to $name…');
  final overall = ValueNotifier<double?>(null);
  final current = ValueNotifier<String>('');
  final cancel = ValueNotifier<bool>(false);
  var finished = false;
  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text('Send to $name'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${bundle.summary} · ${sizeLabel(bundle.total)}', maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 12),
            ValueListenableBuilder<double?>(
              valueListenable: overall,
              builder: (context, v, _) => LinearProgressIndicator(value: v),
            ),
            const SizedBox(height: 6),
            ValueListenableBuilder<String>(
              valueListenable: current,
              builder: (context, s, _) => Text(s, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
            ),
            const SizedBox(height: 6),
            ValueListenableBuilder<String>(valueListenable: status, builder: (context, s, _) => Text(s)),
          ],
        ),
      ),
      actions: [
        ValueListenableBuilder<String>(
          valueListenable: status,
          builder: (context, _, __) => finished
              ? FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))
              : TextButton(
                  onPressed: () {
                    cancel.value = true;
                    status.value = 'Cancelling…';
                  },
                  child: const Text('Cancel'),
                ),
        ),
      ],
    ),
  );
  final meter = TransferMeter();
  final fileMeters = <int, int>{};
  void progress(int sent, int total, int index, String rel) {
    if (!meter.update(sent, total)) return;
    overall.value = total > 0 ? sent / total : null;
    final it = bundle.items[index];
    final fileSent = sent - bundle.items.take(index).fold<int>(0, (a, b) => a + b.size);
    fileMeters[index] = fileSent;
    current.value = 'File ${index + 1}/${bundle.count}: ${p.basename(rel)} '
        '${it.size > 0 ? '${(fileSent.clamp(0, it.size) * 100 ~/ it.size)}%' : ''}';
    status.value = sent >= total && total > 0
        ? 'Finishing… waiting for the receiver to save it'
        : '${total > 0 ? (sent * 100 ~/ total) : 0}% · ${meter.label}';
  }

  final String? error;
  if (target is NearbyDevice) {
    error = await NearbyService.sendBundle(target, bundle,
        onStatus: (s) => current.value = s, onProgress: progress, cancel: cancel);
  } else {
    error = await PhoneHandoff.pushBundle(bundle, target.toString(), onProgress: progress, cancel: cancel);
  }
  finished = true;
  overall.value = error == null ? 1 : overall.value;
  status.value = error ?? 'Sent ✓ ${bundle.count == 1 ? '' : '${bundle.count} files. '}${meter.doneLabel}';
  await dialog;
}

/// Library section listing everything received that isn't a plain video.
class ReceivedScreen extends StatefulWidget {
  const ReceivedScreen({super.key, this.dir});
  final Directory? dir;

  @override
  State<ReceivedScreen> createState() => _ReceivedScreenState();
}

class _ReceivedScreenState extends State<ReceivedScreen> {
  Directory? _dir;
  List<FileSystemEntity> _items = const [];
  final Set<String> _selected = {};

  Future<void> _delete(List<String> paths) async {
    if (paths.isEmpty) return;
    final what = paths.length == 1 ? '“${p.basename(paths.first)}”' : '${paths.length} items';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
        title: Text('Delete $what?'),
        content: Text(Plat.isWindows
            ? 'This removes it from your device (moved to the Recycle Bin). Folders are removed with everything inside.'
            : 'This removes it from your device. Folders are removed with everything inside.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final n = await DeviceMediaService.deletePaths(paths);
    if (!mounted) return;
    _selected.clear();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(n == paths.length ? 'Deleted.' : 'Deleted $n of ${paths.length}.')));
    await _load();
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final dir = widget.dir ?? await receivedRoot();
    final items = dir.existsSync() ? dir.listSync() : <FileSystemEntity>[];
    items.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    if (mounted) setState(() {
      _dir = dir;
      _items = items.where((e) => !p.basename(e.path).startsWith('.')).toList();
    });
  }

  void _open(FileSystemEntity e) {
    if (e is Directory) {
      unawaited(Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => ReceivedScreen(dir: e)))
          .then((_) => _load()));
    } else if (isVideoName(e.path)) {
      unawaited(appRouter.push('/player',
          extra: PlayerSession(title: p.basename(e.path), platform: SocialPlatform.direct, filePath: e.path)));
    } else {
      unawaited(openWithSystem(e.path));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selected.isNotEmpty
            ? '${_selected.length} selected'
            : widget.dir == null
                ? 'Received files'
                : p.basename(widget.dir!.path)),
        actions: [
          if (_selected.isNotEmpty) ...[
            IconButton(
              tooltip: 'Delete',
              onPressed: () => _delete(_selected.toList()),
              icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
            ),
            IconButton(tooltip: 'Cancel', onPressed: () => setState(_selected.clear), icon: const Icon(Icons.close_rounded)),
          ],
          if (Plat.isWindows && _dir != null)
            IconButton(
              tooltip: 'Open in Explorer',
              onPressed: () => openWithSystem(_dir!.path),
              icon: const Icon(Icons.folder_open_rounded),
            ),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: _items.isEmpty
          ? const Center(child: Text('Nothing received yet.\nFiles and folders sent to you appear here.', textAlign: TextAlign.center))
          : ListView.builder(
              itemCount: _items.length,
              itemBuilder: (context, i) {
                final e = _items[i];
                final isDir = e is Directory;
                final stat = e.statSync();
                void toggle() => setState(() {
                      if (!_selected.remove(e.path)) _selected.add(e.path);
                    });
                return ListTile(
                  selected: _selected.contains(e.path),
                  onLongPress: toggle,
                  leading: _selected.isNotEmpty
                      ? Checkbox(value: _selected.contains(e.path), onChanged: (_) => toggle())
                      : Icon(isDir ? Icons.folder_rounded : _iconFor(e.path)),
                  title: Text(p.basename(e.path), maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(isDir ? 'Folder' : sizeLabel(stat.size)),
                  onTap: () => _selected.isNotEmpty ? toggle() : _open(e),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'open') unawaited(openWithSystem(e.path));
                      if (v == 'show') unawaited(showInFolder(e.path));
                      if (v == 'select') toggle();
                      if (v == 'delete') unawaited(_delete([e.path]));
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'open', child: Text('Open with system app')),
                      if (Plat.isWindows) const PopupMenuItem(value: 'show', child: Text('Show in folder')),
                      const PopupMenuItem(value: 'select', child: Text('Select')),
                      const PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                );
              },
            ),
    );
  }

  IconData _iconFor(String path) {
    final ext = p.extension(path).toLowerCase();
    if (isVideoName(path)) return Icons.movie_rounded;
    if (const {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.heic', '.bmp'}.contains(ext)) return Icons.image_rounded;
    if (ext == '.pdf') return Icons.picture_as_pdf_rounded;
    if (const {'.zip', '.rar', '.7z', '.tar', '.gz'}.contains(ext)) return Icons.folder_zip_rounded;
    if (ext == '.apk') return Icons.android_rounded;
    return Icons.insert_drive_file_rounded;
  }
}
