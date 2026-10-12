import 'dart:async';
import 'dart:io';

import 'package:social_save/features/library/transfer_meter.dart';
import 'package:flutter/material.dart';
import 'package:social_save/features/library/nearby_service.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/routing/app_router.dart';

String _size(int bytes) {
  if (bytes <= 0) return '';
  const mb = 1024 * 1024;
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}

/// Hooks the receiving side to the UI. Call once after runApp.
void installNearbyUi() {
  NearbyService.onOffer = (offer) async {
    final context = appRouter.routerDelegate.navigatorKey.currentContext;
    if (context == null || !context.mounted) return false;
    var always = false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          icon: const Icon(Icons.download_for_offline_rounded),
          title: Text('${offer.fromName} wants to send you a video'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(offer.fileName, maxLines: 3, overflow: TextOverflow.ellipsis),
              if (offer.size > 0) Text(_size(offer.size), style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: always,
                onChanged: (v) => setState(() => always = v ?? false),
                title: Text('Always accept from ${offer.fromName}'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Decline')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Accept')),
          ],
        ),
      ),
    );
    if (ok == true && always) await NearbyService.trust(offer.fromId);
    return ok == true;
  };
}

/// Floating card at the bottom while a file arrives, then "Saved · Play".
class NearbyIncomingCard extends StatelessWidget {
  const NearbyIncomingCard({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<IncomingProgress?>(
      valueListenable: NearbyService.incoming,
      builder: (context, v, _) {
        if (v == null) return const SizedBox.shrink();
        final saved = v.done && v.file != null;
        return Positioned(
          left: 12,
          right: 12,
          bottom: 96,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(16),
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                  child: Row(
                    children: [
                      Icon(saved ? Icons.check_circle_rounded : Icons.downloading_rounded),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              saved
                                  ? 'Saved from ${v.fromName}'
                                  : v.done
                                      ? 'Transfer from ${v.fromName} failed'
                                      : 'Receiving from ${v.fromName}… ${v.fraction == null ? '' : '${(v.fraction! * 100).round()}%'}',
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            Text(v.fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
                            if (v.detail.isNotEmpty)
                              Text(v.detail, style: Theme.of(context).textTheme.bodySmall),
                            if (!v.done) ...[
                              const SizedBox(height: 6),
                              LinearProgressIndicator(value: v.fraction),
                            ],
                          ],
                        ),
                      ),
                      if (saved)
                        TextButton(
                          onPressed: () {
                            NearbyService.incoming.value = null;
                            unawaited(appRouter.push(
                              '/player',
                              extra: PlayerSession(
                                title: v.fileName,
                                platform: SocialPlatform.direct,
                                filePath: v.file!.path,
                              ),
                            ));
                          },
                          child: const Text('Play'),
                        ),
                      if (v.done)
                        IconButton(
                          onPressed: () => NearbyService.incoming.value = null,
                          icon: const Icon(Icons.close_rounded),
                        ),
                    ],
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

/// Live list of nearby SocialSave apps. Tapping one sends a video to it:
/// [file] if given, otherwise whatever [pickFile] returns.
class NearbyDeviceChips extends StatefulWidget {
  const NearbyDeviceChips({super.key, this.file, this.pickFile, this.dense = false});

  final File? file;
  final Future<File?> Function()? pickFile;
  final bool dense;

  @override
  State<NearbyDeviceChips> createState() => _NearbyDeviceChipsState();
}

class _NearbyDeviceChipsState extends State<NearbyDeviceChips> {
  @override
  void initState() {
    super.initState();
    NearbyService.ping();
  }

  Future<void> _tap(NearbyDevice device) async {
    final file = widget.file ?? await widget.pickFile?.call();
    if (file == null || !mounted) return;
    await sendToNearby(context, device, file);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<NearbyDevice>>(
      valueListenable: NearbyService.devices,
      builder: (context, list, _) {
        if (list.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Looking for phones and PCs with SocialSave open on this Wi-Fi…',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          );
        }
        return Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final d in list)
              ActionChip(
                key: ValueKey('nearby-${d.id}'),
                avatar: Icon(d.isPc ? Icons.computer_rounded : Icons.smartphone_rounded, size: 18),
                label: Text(d.name),
                tooltip: 'Send a video to ${d.name}',
                onPressed: () => _tap(d),
              ),
          ],
        );
      },
    );
  }
}

/// Sends with a progress dialog on this side.
Future<void> sendToNearby(BuildContext context, NearbyDevice device, File file) async {
  final status = ValueNotifier<String>('Connecting to ${device.name}…');
  final progress = ValueNotifier<double?>(null);
  var finished = false;
  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text('Send to ${device.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(file.path.split(Platform.pathSeparator).last, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 12),
          ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (context, v, _) => LinearProgressIndicator(value: v),
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<String>(valueListenable: status, builder: (context, s, _) => Text(s)),
        ],
      ),
      actions: [
        ValueListenableBuilder<String>(
          valueListenable: status,
          builder: (context, _, __) => TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(finished ? 'Done' : 'Hide'),
          ),
        ),
      ],
    ),
  );
  final meter = TransferMeter();
  final error = await NearbyService.sendTo(
    device,
    file,
    onStatus: (s) => status.value = s,
    onProgress: (sent, total) {
      if (!meter.update(sent, total)) return;
      progress.value = total > 0 ? sent / total : null;
      status.value = 'Sending… ${total > 0 ? (sent * 100 ~/ total) : 0}% · ${meter.label}';
    },
  );
  finished = true;
  progress.value = error == null ? 1 : 0;
  status.value = error ?? 'Sent. It is saved on ${device.name}. ${meter.doneLabel}';
  await dialog;
}
