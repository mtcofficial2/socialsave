import 'dart:async';

import 'package:flutter/material.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/library/bundle_transfer.dart';
import 'package:social_save/features/library/nearby_service.dart';
import 'package:social_save/features/library/share_session.dart';
import 'package:social_save/features/library/transfer_meter.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/routing/app_router.dart';

/// Hooks [ShareSession] to the UI. Called from installNearbyUi().
void installSessionUi() {
  ShareSession.install();
  ShareSession.onRequest = (name, kind) async {
    final context = appRouter.routerDelegate.navigatorKey.currentContext;
    if (context == null || !context.mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.link_rounded),
        title: Text('$name wants to connect'),
        content: const Text(
          'While connected, you can both send videos and files to each other '
          'without scanning again. Files from them are saved automatically.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Decline')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Connect')),
        ],
      ),
    );
    return ok == true;
  };
  ShareSession.onOpened = () => unawaited(openSessionScreen());
}

/// Shows the "Connected to …" screen (once).
Future<void> openSessionScreen([BuildContext? from]) async {
  if (ShareSession.screenOpen) return;
  final context = from ?? appRouter.routerDelegate.navigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  ShareSession.screenOpen = true;
  try {
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => const SessionScreen()),
    );
  } finally {
    ShareSession.screenOpen = false;
  }
}

/// Pick a nearby device (same Wi-Fi, USB cable, PC) and stay connected to it.
Future<void> showConnectPicker(BuildContext context) async {
  if (ShareSession.active) {
    await openSessionScreen(context);
    return;
  }
  NearbyService.ping();
  final device = await showDialog<NearbyDevice>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.link_rounded),
      title: const Text('Connect to a device'),
      content: SizedBox(
        width: 420,
        child: ValueListenableBuilder<List<NearbyDevice>>(
          valueListenable: NearbyService.devices,
          builder: (context, list, _) {
            final small = Theme.of(context).textTheme.bodySmall;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Stay connected and send videos or files both ways, as many times as you like.',
                  style: small,
                ),
                const SizedBox(height: 12),
                if (list.isEmpty)
                  const Row(
                    children: [
                      SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 10),
                      Expanded(child: Text('Looking for SocialSave on this Wi-Fi or USB cable…')),
                    ],
                  )
                else
                  for (final d in list)
                    ListTile(
                      key: ValueKey('connect-${d.id}-${d.link}'),
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(d.isCable
                          ? Icons.cable_rounded
                          : (d.isPc ? Icons.computer_rounded : Icons.smartphone_rounded)),
                      title: Text(d.name),
                      subtitle: Text('${d.playerName} · ${d.isCable ? 'cable' : 'Wi-Fi'}'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.pop(context, d),
                    ),
                const SizedBox(height: 8),
                Text(
                  Plat.isAndroid
                      ? 'No Wi-Fi? Use Send › Fast share (hotspot): scanning its QR connects you too.'
                      : 'Phone on its own hotspot? Join that Wi-Fi on this PC, then it shows up here.',
                  style: small,
                ),
              ],
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    ),
  );
  if (device == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(
    duration: const Duration(seconds: 60),
    content: Text('Waiting for ${device.name} to accept…'),
  ));
  final error = await ShareSession.connect(host: device.host, port: device.port, link: device.link);
  messenger.hideCurrentSnackBar();
  if (error != null) {
    messenger.showSnackBar(SnackBar(content: Text(error)));
    return;
  }
  if (context.mounted) await openSessionScreen(context);
}

/// Slim "Connected to …" strip for the share cards, so a session that runs
/// in the background is one tap away.
class SessionBanner extends StatelessWidget {
  const SessionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SessionPeer?>(
      valueListenable: ShareSession.peer,
      builder: (context, peer, _) {
        if (peer == null) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Material(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              key: const ValueKey('session-banner'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => openSessionScreen(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.link_rounded, color: scheme.onPrimaryContainer, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Connected to ${peer.name} · ${peer.linkLabel}',
                        style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text('Open', style: TextStyle(color: scheme.onPrimaryContainer)),
                    Icon(Icons.chevron_right_rounded, color: scheme.onPrimaryContainer),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// "Connected to <device>": send more at any time, see what came in.
class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key});

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  SessionPeer? _last;
  bool _picking = false;

  Future<void> _send({required bool folder}) async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final bundle = folder ? await pickAnyFolder() : await pickAnyFiles();
      if (bundle == null) return;
      ShareSession.enqueue([for (final it in bundle.items) it.file]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open the picker: $e')));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _disconnect() async {
    await ShareSession.disconnect();
  }

  void _open(SessionItem it) {
    final f = it.file;
    if (f == null) return;
    if (isVideoName(f.path)) {
      unawaited(appRouter.push(
        '/player',
        extra: PlayerSession(title: it.name, platform: SocialPlatform.direct, filePath: f.path),
      ));
    } else {
      unawaited(openWithSystem(f.path));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ValueListenableBuilder<SessionPeer?>(
      valueListenable: ShareSession.peer,
      builder: (context, peer, _) {
        if (peer != null) _last = peer;
        final shown = peer ?? _last;
        return ValueListenableBuilder<String>(
          valueListenable: ShareSession.state,
          builder: (context, state, _) => Scaffold(
            appBar: AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    peer == null ? 'Disconnected' : 'Connected to ${peer.name}',
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (shown != null)
                    Text(
                      '${shown.kind == 'pc' ? 'PC' : 'Phone'} · ${shown.linkLabel}',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
              actions: [
                if (peer != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: TextButton.icon(
                      key: const ValueKey('session-disconnect'),
                      style: TextButton.styleFrom(foregroundColor: scheme.error),
                      onPressed: _disconnect,
                      icon: const Icon(Icons.link_off_rounded),
                      label: const Text('Disconnect'),
                    ),
                  ),
              ],
            ),
            body: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (peer == null)
                    _Banner(
                      color: scheme.errorContainer,
                      onColor: scheme.onErrorContainer,
                      icon: Icons.link_off_rounded,
                      text: ShareSession.endReason.isEmpty ? 'Disconnected.' : ShareSession.endReason,
                    )
                  else if (state == 'reconnecting')
                    _Banner(
                      color: scheme.tertiaryContainer,
                      onColor: scheme.onTertiaryContainer,
                      icon: Icons.sync_problem_rounded,
                      text: 'Can\'t reach ${peer.name} right now… keep SocialSave open on both devices.',
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            key: const ValueKey('session-send'),
                            style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                            onPressed: peer == null || _picking ? null : () => _send(folder: false),
                            icon: const Icon(Icons.send_rounded),
                            label: const Text('Send'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          key: const ValueKey('session-send-folder'),
                          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)),
                          onPressed: peer == null || _picking ? null : () => _send(folder: true),
                          icon: const Icon(Icons.drive_folder_upload_rounded),
                          label: const Text('Folder'),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      peer == null
                          ? 'Connect again from Nearby share › Connect, or scan a new hotspot QR.'
                          : 'Pick videos or any files — they queue and go one after another. '
                              'Anything ${peer.name} sends appears here and is saved automatically.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  const Divider(height: 24),
                  Expanded(
                    child: ValueListenableBuilder<int>(
                      valueListenable: ShareSession.revision,
                      builder: (context, _, __) {
                        final list = ShareSession.items.reversed.toList();
                        if (list.isEmpty) {
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.swap_vert_rounded, size: 48, color: scheme.outline),
                                  const SizedBox(height: 8),
                                  Text('Nothing sent yet', style: theme.textTheme.titleMedium),
                                ],
                              ),
                            ),
                          );
                        }
                        return ListView.separated(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                          itemCount: list.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 2),
                          itemBuilder: (context, i) => _ItemTile(
                            item: list[i],
                            peerName: shown?.name ?? '',
                            onOpen: _open,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.color, required this.onColor, required this.icon, required this.text});
  final Color color;
  final Color onColor;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(icon, color: onColor),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: TextStyle(color: onColor))),
          ],
        ),
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item, required this.peerName, required this.onOpen});
  final SessionItem item;
  final String peerName;
  final void Function(SessionItem) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final it = item;
    final failed = it.state == SessionItemState.failed;
    final done = it.state == SessionItemState.done;
    final status = switch (it.state) {
      SessionItemState.queued => 'Queued',
      SessionItemState.sending => it.fraction == null ? 'Sending…' : 'Sending… ${(it.fraction! * 100).floor()}%',
      SessionItemState.receiving => it.fraction == null ? 'Receiving…' : 'Receiving… ${(it.fraction! * 100).floor()}%',
      SessionItemState.done => it.outgoing ? 'Sent' : 'Received',
      SessionItemState.failed => 'Failed',
    };
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: failed ? scheme.errorContainer : scheme.secondaryContainer,
              child: Icon(
                it.outgoing ? Icons.north_east_rounded : Icons.south_west_rounded,
                size: 18,
                color: failed ? scheme.onErrorContainer : scheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    [
                      '${it.outgoing ? 'To' : 'From'} $peerName',
                      status,
                      if (it.size > 0) formatBytes(it.size),
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                  if (it.active || it.state == SessionItemState.queued) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: it.state == SessionItemState.queued ? 0 : it.fraction),
                  ],
                  if (it.detail.isNotEmpty && !(done && it.outgoing && it.detail == 'Sent'))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        it.detail,
                        style: theme.textTheme.bodySmall?.copyWith(color: failed ? scheme.error : null),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            if (done && !it.outgoing && it.file != null)
              TextButton(
                onPressed: () => onOpen(it),
                child: Text(isVideoName(it.file!.path) ? 'Play' : 'Open'),
              )
            else if (it.state == SessionItemState.queued || failed)
              IconButton(
                tooltip: 'Remove',
                onPressed: () => ShareSession.remove(it),
                icon: const Icon(Icons.close_rounded),
              ),
          ],
        ),
      ),
    );
  }
}

