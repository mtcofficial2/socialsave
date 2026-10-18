import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/library/bundle_ui.dart';
import 'package:social_save/features/library/hotspot_share.dart';
import 'package:social_save/features/library/nearby_service.dart';
import 'package:social_save/features/library/nearby_ui.dart';
import 'package:social_save/features/library/phone_handoff.dart';
import 'package:social_save/features/library/session_ui.dart';
import 'package:social_save/features/library/share_session.dart';
import 'package:url_launcher/url_launcher.dart';

/// One place for everything sharing: nearby devices (radar), send, receive,
/// connect with a code or QR, send text, and the other ways.
class ShareHubScreen extends StatefulWidget {
  const ShareHubScreen({super.key});

  @override
  State<ShareHubScreen> createState() => _ShareHubScreenState();
}

class _ShareHubScreenState extends State<ShareHubScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();
  Timer? _rescan;

  @override
  void initState() {
    super.initState();
    NearbyService.ping();
    _rescan = Timer.periodic(const Duration(seconds: 6), (_) => NearbyService.ping());
  }

  @override
  void dispose() {
    _rescan?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  IconData _icon(NearbyDevice d) =>
      d.isCable ? Icons.cable_rounded : (d.isPc ? Icons.computer_rounded : Icons.smartphone_rounded);

  Future<void> _deviceActions(NearbyDevice d) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text('Send to ${d.name}', style: const TextStyle(fontWeight: FontWeight.w700))),
            ListTile(leading: const Icon(Icons.movie_rounded), title: const Text('Send a video'), onTap: () => Navigator.pop(ctx, 'video')),
            ListTile(leading: const Icon(Icons.file_present_rounded), title: const Text('Send files'), onTap: () => Navigator.pop(ctx, 'files')),
            ListTile(leading: const Icon(Icons.drive_folder_upload_rounded), title: const Text('Send a folder'), onTap: () => Navigator.pop(ctx, 'folder')),
            ListTile(leading: const Icon(Icons.text_snippet_rounded), title: const Text('Send text or a link'), onTap: () => Navigator.pop(ctx, 'text')),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'video':
        final file = await pickVideoFile();
        if (file != null && mounted) await sendToNearby(context, d, file);
      case 'files':
        await pickAndSendBundle(context, folder: false);
      case 'folder':
        await pickAndSendBundle(context, folder: true);
      case 'text':
        await showSendTextDialog(context, device: d);
    }
  }

  Widget _radar(BuildContext context, List<NearbyDevice> list) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: list.isEmpty
          ? 'Searching for nearby devices'
          : '${list.length} nearby ${list.length == 1 ? 'device' : 'devices'} found',
      child: SizedBox(
        height: 260,
        child: LayoutBuilder(builder: (context, c) {
          final size = math.min(c.maxWidth, 260.0);
          final centre = Offset(c.maxWidth / 2, 130);
          return Stack(
            alignment: Alignment.center,
            children: [
              AnimatedBuilder(
                animation: _pulse,
                builder: (context, _) => CustomPaint(
                  size: Size(c.maxWidth, 260),
                  painter: _RadarPainter(_pulse.value, scheme.primary),
                ),
              ),
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.primaryContainer),
                child: Icon(Plat.isWindows ? Icons.computer_rounded : Icons.smartphone_rounded, color: scheme.onPrimaryContainer, size: 30),
              ),
              for (var i = 0; i < list.length && i < 8; i++)
                Positioned(
                  left: centre.dx + math.cos(i * 2 * math.pi / math.min(list.length, 8) - math.pi / 2) * (size / 2 - 38) - 36,
                  top: centre.dy + math.sin(i * 2 * math.pi / math.min(list.length, 8) - math.pi / 2) * 92 - 36,
                  child: _avatar(context, list[i]),
                ),
            ],
          );
        }),
      ),
    );
  }

  Widget _avatar(BuildContext context, NearbyDevice d) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Send to ${d.name}, ${d.isPc ? 'computer' : 'phone'}${d.isCable ? ', over cable' : ''}',
      child: InkWell(
        key: ValueKey('hub-device-${d.id}'),
        borderRadius: BorderRadius.circular(40),
        onTap: () => _deviceActions(d),
        child: SizedBox(
          width: 72,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: scheme.secondaryContainer,
                child: Icon(_icon(d), color: scheme.onSecondaryContainer),
              ),
              const SizedBox(height: 2),
              Text(d.name.isEmpty ? d.playerName : d.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(BuildContext context, {required IconData icon, required String title, required String sub, required VoidCallback onTap, Key? key}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        key: key,
        leading: Icon(icon),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(sub),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send / Receive')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                ValueListenableBuilder<List<NearbyDevice>>(
                  valueListenable: NearbyService.devices,
                  builder: (context, list, _) => Column(
                    children: [
                      _radar(context, list),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: Text(
                          list.isEmpty
                              ? 'Looking for devices with SocialSave open on this Wi-Fi...'
                              : 'Tap a device to send. You are visible as "${NearbyService.name}".',
                          key: ValueKey(list.isEmpty),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const SessionBanner(),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      key: const ValueKey('hub-send'),
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                      onPressed: () => pickAndSendBundle(context, folder: false),
                      icon: const Icon(Icons.send_rounded),
                      label: const Text('Send files'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('hub-receive'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)),
                      onPressed: () => showReceiveFromPhone(context),
                      icon: const Icon(Icons.download_rounded),
                      label: const Text('Receive'),
                    ),
                  ),
                ]),
                const SizedBox(height: 14),
                if (HotspotShareAvailability.canFastConnect)
                  _action(context,
                      key: const ValueKey('hub-fast-connect'),
                      icon: Icons.bolt_rounded,
                      title: 'Fast connect (no Wi-Fi needed)',
                      sub: 'Starts a private hotspot and shows a QR. The other phone scans it and joins with one tap.',
                      onTap: () => showHotspotQuickShare(context)),
                _action(context,
                    key: const ValueKey('hub-connect'),
                    icon: Icons.qr_code_scanner_rounded,
                    title: 'Connect with code or QR',
                    sub: 'Enter the pairing code or scan the other device, then send both ways.',
                    onTap: () => showConnectPicker(context)),
                _action(context,
                    key: const ValueKey('hub-text'),
                    icon: Icons.text_snippet_rounded,
                    title: 'Send text or link',
                    sub: 'Paste a message, link or your clipboard to a nearby device.',
                    onTap: () => showSendTextDialog(context)),
                _action(context,
                    icon: Icons.inventory_2_rounded,
                    title: 'Received files',
                    sub: 'Everything other devices sent to you.',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ReceivedScreen()))),
                _action(context,
                    icon: Icons.chat_bubble_outline_rounded,
                    title: 'Received text',
                    sub: 'Messages and links sent to you.',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ReceivedTextScreen()))),
                _action(context,
                    icon: Icons.verified_user_rounded,
                    title: 'Trusted devices',
                    sub: 'Devices that can send to you without asking.',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TrustedDevicesScreen()))),
                const SizedBox(height: 4),
                ExpansionTile(
                  title: const Text('More ways to connect'),
                  subtitle: const Text('Hotspot guide, USB cable'),
                  childrenPadding: const EdgeInsets.symmetric(vertical: 6),
                  children: const [
                    HotspotQuickButtons(),
                    SizedBox(height: 8),
                    Align(alignment: Alignment.centerLeft, child: UsbHint()),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Fast connect is the existing hotspot share (Android local-only hotspot).
class HotspotShareAvailability {
  static bool get canFastConnect => HotspotShare.hostSupported;
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.t, this.color);
  final double t;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final maxR = math.min(size.width, size.height) / 2;
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1.0;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: (1 - p) * 0.35);
      canvas.drawCircle(c, 32 + (maxR - 32) * p, paint);
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.t != t;
}

/// Pick a nearby device (if needed), then send [text] (prefilled from the
/// clipboard when empty).
Future<void> showSendTextDialog(BuildContext context, {NearbyDevice? device}) async {
  final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
  if (!context.mounted) return;
  final ctl = TextEditingController();
  NearbyDevice? target = device ?? (NearbyService.devices.value.length == 1 ? NearbyService.devices.value.first : null);
  final peer = ShareSession.peer.value;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Send text or link'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: ctl,
                autofocus: true,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(hintText: 'Type or paste here', border: OutlineInputBorder()),
              ),
              if (clip.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() => ctl.text = clip),
                    icon: const Icon(Icons.content_paste_rounded, size: 18),
                    label: const Text('Paste from clipboard'),
                  ),
                ),
              const SizedBox(height: 4),
              if (device == null)
                ValueListenableBuilder<List<NearbyDevice>>(
                  valueListenable: NearbyService.devices,
                  builder: (context, list, _) => list.isEmpty
                      ? Text(peer == null ? 'No nearby device found yet. Open SocialSave on the other device.' : 'No nearby device found.')
                      : Wrap(spacing: 8, children: [
                          for (final d in list)
                            ChoiceChip(
                              label: Text(d.name.isEmpty ? d.playerName : d.name),
                              selected: target?.id == d.id,
                              onSelected: (_) => setState(() => target = d),
                            ),
                        ]),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send')),
        ],
      ),
    ),
  );
  final text = ctl.text.trim();
  ctl.dispose();
  if (go != true || text.isEmpty || !context.mounted) return;
  final t = target;
  if (t == null) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick a nearby device first.')));
    return;
  }
  final err = await NearbyService.sendText(t, text);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Sent to ${t.name}.')));
}

bool _looksLikeLink(String s) => RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(s.trim());

/// Pop-up shown on the receiving device when text arrives.
Future<void> showIncomingText(BuildContext context, String from, String text) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Text from $from'),
      content: SingleChildScrollView(child: SelectableText(text)),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (ctx.mounted) Navigator.pop(ctx);
          },
          child: const Text('Copy'),
        ),
        if (_looksLikeLink(text))
          TextButton(
            onPressed: () async {
              await launchUrl(Uri.parse(text.trim()), mode: LaunchMode.externalApplication);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Open link'),
          ),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
      ],
    ),
  );
}

class ReceivedTextScreen extends StatefulWidget {
  const ReceivedTextScreen({super.key});

  @override
  State<ReceivedTextScreen> createState() => _ReceivedTextScreenState();
}

class _ReceivedTextScreenState extends State<ReceivedTextScreen> {
  List<(String, String)>? _items;

  @override
  void initState() {
    super.initState();
    NearbyService.receivedTexts().then((v) {
      if (mounted) setState(() => _items = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('Received text')),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? const Center(child: Text('Nothing received yet.'))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) => Semantics(
                    label: 'Text from ${items[i].$1}: ${items[i].$2}',
                    child: ListTile(
                      title: Text(items[i].$2, maxLines: 3, overflow: TextOverflow.ellipsis),
                      subtitle: Text('From ${items[i].$1}'),
                      trailing: const Icon(Icons.copy_rounded, size: 20),
                      onTap: () => showIncomingText(context, items[i].$1, items[i].$2),
                    ),
                  ),
                ),
    );
  }
}

class TrustedDevicesScreen extends StatefulWidget {
  const TrustedDevicesScreen({super.key});

  @override
  State<TrustedDevicesScreen> createState() => _TrustedDevicesScreenState();
}

class _TrustedDevicesScreenState extends State<TrustedDevicesScreen> {
  List<(String, String)>? _items;

  Future<void> _load() async {
    final v = await NearbyService.trustedDevices();
    if (mounted) setState(() => _items = v);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('Trusted devices')),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No trusted devices. When someone sends you a file, choose "Always accept" to add them here.', textAlign: TextAlign.center),
                  ),
                )
              : ListView(
                  children: [
                    for (final d in items)
                      ListTile(
                        leading: const Icon(Icons.verified_user_rounded),
                        title: Text(d.$2),
                        subtitle: const Text('Can send files without asking'),
                        trailing: TextButton(
                          onPressed: () async {
                            await NearbyService.untrust(d.$1);
                            await _load();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${d.$2} will be asked next time.')));
                            }
                          },
                          child: const Text('Revoke'),
                        ),
                      ),
                  ],
                ),
    );
  }
}