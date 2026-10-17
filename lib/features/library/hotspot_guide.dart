import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/library/hotspot_share.dart';

/// 1.0.39: guided Hotspot share. One blocker at a time, each with a clear
/// step card and one button; the dialog moves on by itself when the blocker
/// is gone (permission granted, Location or Hotspot turned on...).
class GuideStep {
  const GuideStep({
    required this.icon,
    required this.title,
    required this.text,
    this.action,
    this.onAction,
    this.secondary,
    this.onSecondary,
    this.waiting,
  });

  final IconData icon;
  final String title;
  final String text;
  final String? action;
  final VoidCallback? onAction;
  final String? secondary;
  final VoidCallback? onSecondary;

  /// Shown with a small spinner while the app watches for the change.
  final String? waiting;
}

class GuideStepCard extends StatelessWidget {
  const GuideStepCard({super.key, required this.step, this.child});
  final GuideStep step;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      key: const ValueKey('guide-step'),
      margin: EdgeInsets.zero,
      color: scheme.secondaryContainer.withValues(alpha: 0.55),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(step.icon, color: scheme.primary, size: 28),
                const SizedBox(width: 10),
                Expanded(child: Text(step.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
              ],
            ),
            const SizedBox(height: 8),
            Text(step.text, style: theme.textTheme.bodyMedium),
            ?child,
            if (step.waiting != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(step.waiting!, style: theme.textTheme.bodySmall)),
                ],
              ),
            ],
            if (step.action != null) ...[
              const SizedBox(height: 12),
              FilledButton(
                key: const ValueKey('guide-action'),
                onPressed: step.onAction,
                child: Text(step.action!),
              ),
            ],
            if (step.secondary != null)
              TextButton(
                key: const ValueKey('guide-secondary'),
                onPressed: step.onSecondary,
                child: Text(step.secondary!),
              ),
          ],
        ),
      ),
    );
  }
}

/// Name/password of the phone's own hotspot, typed once (remembered).
class SystemHotspotForm extends StatefulWidget {
  const SystemHotspotForm({super.key, required this.onDone, this.ssid = '', this.password = ''});
  final String ssid;
  final String password;
  final void Function(String ssid, String password) onDone;

  @override
  State<SystemHotspotForm> createState() => _SystemHotspotFormState();
}

class _SystemHotspotFormState extends State<SystemHotspotForm> {
  late final _ssid = TextEditingController(text: widget.ssid);
  late final _pass = TextEditingController(text: widget.password);
  bool _show = false;

  @override
  void dispose() {
    _ssid.dispose();
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final okPass = _pass.text.isEmpty || _pass.text.length >= 8;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey('sys-hs-ssid'),
          controller: _ssid,
          decoration: const InputDecoration(labelText: 'Hotspot name', isDense: true),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('sys-hs-pass'),
          controller: _pass,
          obscureText: !_show,
          decoration: InputDecoration(
            labelText: 'Hotspot password',
            isDense: true,
            errorText: okPass ? null : 'Hotspot passwords have at least 8 characters',
            suffixIcon: IconButton(
              tooltip: _show ? 'Hide' : 'Show',
              icon: Icon(_show ? Icons.visibility_off_rounded : Icons.visibility_rounded),
              onPressed: () => setState(() => _show = !_show),
            ),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const ValueKey('sys-hs-continue'),
          onPressed: _ssid.text.trim().isEmpty || !okPass ? null : () => widget.onDone(_ssid.text.trim(), _pass.text),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

/// Standard Wi-Fi QR ("WIFI:T:WPA;S:name;P:pass;;"): any phone camera joins
/// the hotspot from it, even without SocialSave.
String wifiQrData(String ssid, String password) {
  String esc(String s) => s.replaceAllMapped(RegExp(r'([\\;,:"])'), (m) => '\\${m[1]}');
  return password.isEmpty ? 'WIFI:T:nopass;S:${esc(ssid)};;' : 'WIFI:T:WPA;S:${esc(ssid)};P:${esc(password)};;';
}

Future<void> showWifiQr(BuildContext context, HotspotInfo info) => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Wi-Fi QR'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ColoredBox(
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: QrImageView(key: const ValueKey('wifi-qr'), data: wifiQrData(info.ssid, info.password), size: 200),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Scan with the other phone\'s camera to join "${info.ssid}". '
              'Then open SocialSave › Receive and type the code.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );

/// "Connection help": a short checklist and plain-words fixes for the usual
/// failures.
Future<void> showConnectionHelp(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        Widget check(String t) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.check_circle_outline_rounded, size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(child: Text(t)),
                ],
              ),
            );
        Widget fix(String problem, String answer) => ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 10),
              title: Text(problem, style: const TextStyle(fontWeight: FontWeight.w600)),
              expandedAlignment: Alignment.centerLeft,
              children: [Text(answer)],
            );
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              key: const ValueKey('connection-help'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Connection help', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                Text('Before you start', style: theme.textTheme.titleSmall),
                check('Both devices have SocialSave open.'),
                check(Plat.isWindows
                    ? 'This PC\'s Wi-Fi is on and it is online (Windows needs a connection to share).'
                    : 'Sending phone: Nearby devices (or Location) allowed. Receiving phone: Wi-Fi on.'),
                check('Keep the devices within a few metres of each other.'),
                check('Already on the same Wi-Fi or a USB cable? Send and Receive find each other without a hotspot.'),
                const SizedBox(height: 12),
                Text('If something goes wrong', style: theme.textTheme.titleSmall),
                fix('"The hotspot could not start"',
                    'Turn off the phone\'s own Mobile Hotspot and try again, or turn it on and let SocialSave use it: '
                        'Hotspot share shows the steps.'),
                fix('The other phone can\'t join',
                    'Make sure its Wi-Fi is on and tap Connect if Android asks. Move the phones closer. '
                        'Still stuck: join the Wi-Fi by hand with the name and password shown, then type the code in Receive.'),
                fix('Joined, but "Can\'t find the other device"',
                    'Keep the Hotspot share window open on the sender. On a PC, allow SocialSave in Windows Firewall '
                        '(the Allow button). Then tap Retry.'),
                fix('It\'s slow (1-2 MB/s)',
                    'A phone or PC that is also on a 2.4 GHz Wi-Fi network keeps the hotspot on that channel. '
                        'Turn its Wi-Fi off (phone) or disconnect it (PC), choose 5 GHz, and start again. '
                        'A USB cable is the fastest.'),
                fix('The QR scanner doesn\'t open',
                    'Allow the camera for SocialSave. Some phones only let apps use the front camera: hold the '
                        'other screen facing you. Or type the code instead.'),
                fix('Windows: "Mobile hotspot is not available"',
                    'Turn on Wi-Fi, connect the PC to the internet, then use Open Mobile hotspot settings. '
                        'Company PCs may block it by policy: send over the same Wi-Fi instead.'),
              ],
            ),
          ),
        );
      },
    );

/// Receiver: a banner while Wi-Fi is off, with a button to turn it on
/// (Wi-Fi panel on Android 10+). Disappears by itself once Wi-Fi is on.
class WifiOffBanner extends StatefulWidget {
  const WifiOffBanner({super.key});

  @override
  State<WifiOffBanner> createState() => _WifiOffBannerState();
}

class _WifiOffBannerState extends State<WifiOffBanner> {
  bool _off = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    if (!HotspotShare.supported) return;
    unawaited(_check());
    _poll = Timer.periodic(const Duration(milliseconds: 1500), (_) => _check());
  }

  Future<void> _check() async {
    try {
      final s = await HotspotShare.status();
      final off = s['wifiOn'] != true;
      if (mounted && off != _off) setState(() => _off = off);
    } catch (_) {}
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_off) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: GuideStepCard(
        step: GuideStep(
          icon: Icons.wifi_off_rounded,
          title: 'Turn on Wi-Fi first',
          text: 'Wi-Fi is off. Joining the other phone\'s hotspot needs Wi-Fi on (no internet needed).',
          action: 'Turn on Wi-Fi',
          onAction: () => HotspotShare.openSettings('wifi'),
          waiting: 'This goes away by itself when Wi-Fi is on.',
        ),
      ),
    );
  }
}

/// Receiver: live steps after scanning (Joining hotspot…, Finding the other
/// device…, Connected) and a fix-it message with Retry on failure.
class JoinProgress {
  JoinProgress(this.ssid);
  final String ssid;
  final ValueNotifier<int> step = ValueNotifier<int>(0); // 0 joining, 1 finding, 2 connected
  final ValueNotifier<String?> error = ValueNotifier<String?>(null);
  final ValueNotifier<String?> detail = ValueNotifier<String?>(null);
  Completer<bool>? _choice;

  /// Shows the failure and waits for Retry (true) or Close (false).
  Future<bool> fail(String message) {
    error.value = message;
    _choice = Completer<bool>();
    return _choice!.future;
  }

  void _answer(bool retry) {
    error.value = null;
    if (!(_choice?.isCompleted ?? true)) _choice!.complete(retry);
  }
}

class JoinProgressDialog extends StatelessWidget {
  const JoinProgressDialog({super.key, required this.progress});
  final JoinProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget row(int i, String label, int now) {
      final done = now > i;
      final active = now == i;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: done
                  ? Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary, size: 22)
                  : active
                      ? const Padding(padding: EdgeInsets.all(3), child: CircularProgressIndicator(strokeWidth: 2.4))
                      : Icon(Icons.radio_button_unchecked_rounded, color: theme.colorScheme.outline, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: active ? theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700) : theme.textTheme.bodyLarge),
            ),
          ],
        ),
      );
    }

    return PopScope(
      canPop: false,
      child: AlertDialog(
        key: const ValueKey('join-progress'),
        title: const Text('Connecting'),
        content: SizedBox(
          width: 360,
          child: ValueListenableBuilder<String?>(
            valueListenable: progress.error,
            builder: (context, err, _) => ValueListenableBuilder<int>(
              valueListenable: progress.step,
              builder: (context, now, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  row(0, 'Joining hotspot "${progress.ssid}"…', now),
                  row(1, 'Finding the other device…', now),
                  row(2, 'Connected', now),
                  ValueListenableBuilder<String?>(
                    valueListenable: progress.detail,
                    builder: (context, d, _) => d == null
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(d, style: theme.textTheme.bodySmall),
                          ),
                  ),
                  if (err != null) ...[
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.error_outline_rounded, color: theme.colorScheme.error),
                        const SizedBox(width: 8),
                        Expanded(child: Text(err, key: const ValueKey('join-error'))),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(onPressed: () => showConnectionHelp(context), child: const Text('Connection help')),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          ValueListenableBuilder<String?>(
            valueListenable: progress.error,
            builder: (context, err, _) => err == null
                ? const SizedBox.shrink()
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(onPressed: () => progress._answer(false), child: const Text('Close')),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const ValueKey('join-retry'),
                        onPressed: () => progress._answer(true),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
