import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/library/hotspot_share.dart';
import 'package:social_save/features/library/pc_hotspot.dart';
import 'package:permission_handler/permission_handler.dart';

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


// ------------------------------------------------------------ 1.0.40 preflight

/// One thing a transfer needs (permission, Location, Wi-Fi, Hotspot...).
/// [fix] opens the right system screen or prompt and may return the
/// one-line instruction to show (null keeps [instruction]).
class PreflightItem {
  const PreflightItem({
    required this.label,
    required this.instruction,
    required this.check,
    required this.fix,
    this.altLabel,
    this.alt,
  });
  final String? altLabel;
  final Future<String?> Function()? alt;
  final String label;
  final String instruction;
  final Future<bool> Function() check;
  final Future<String?> Function() fix;
}

/// Xender-style pre-flight: checks each item in order and, for the first
/// missing one, opens the right screen BY ITSELF with a one-line
/// instruction. When the user comes back it re-checks and moves on.
/// Returns true only when every item is satisfied.
Future<bool> runPreflight(BuildContext context, {required String title, required List<PreflightItem> items}) async {
  try {
    var ok = true;
    for (final i in items) {
      if (!await i.check()) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  } catch (_) {}
  if (!context.mounted) return false;
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (_) => PreflightDialog(title: title, items: items),
      ) ??
      false;
}

class PreflightDialog extends StatefulWidget {
  const PreflightDialog({super.key, required this.title, required this.items});
  final String title;
  final List<PreflightItem> items;

  @override
  State<PreflightDialog> createState() => _PreflightDialogState();
}

class _PreflightDialogState extends State<PreflightDialog> with WidgetsBindingObserver {
  late final List<bool> _ok = List<bool>.filled(widget.items.length, false);
  int _current = 0;
  bool _done = false;
  bool _busy = false;
  String? _note;
  final Set<int> _opened = {};
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_advance());
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_advance()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from Settings: re-check straight away.
    if (state == AppLifecycleState.resumed) unawaited(_advance());
  }

  Future<void> _advance() async {
    if (_busy || _done || !mounted) return;
    _busy = true;
    try {
      for (var i = 0; i < widget.items.length; i++) {
        bool ok;
        try {
          ok = await widget.items[i].check();
        } catch (_) {
          ok = false;
        }
        if (!mounted) return;
        if (!ok) {
          setState(() {
            for (var j = 0; j < widget.items.length; j++) {
              _ok[j] = j < i;
            }
            if (_current != i) _note = null;
            _current = i;
          });
          // Open the screen for this item by itself, once.
          if (_opened.add(i)) await _fix(i);
          return;
        }
      }
      setState(() {
        for (var j = 0; j < _ok.length; j++) {
          _ok[j] = true;
        }
        _done = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      _busy = false;
    }
  }

  Future<void> _fix(int i) async {
    try {
      final note = await widget.items[i].fix();
      if (mounted && note != null) setState(() => _note = note);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = widget.items;
    return AlertDialog(
      key: const ValueKey('preflight-dialog'),
      title: Text(widget.title),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < items.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: _ok[i]
                          ? Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary, size: 22)
                          : (i == _current && !_done)
                              ? const Padding(padding: EdgeInsets.all(3), child: CircularProgressIndicator(strokeWidth: 2))
                              : Icon(Icons.radio_button_unchecked_rounded, color: theme.colorScheme.outline, size: 22),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        items[i].label,
                        style: TextStyle(fontWeight: i == _current && !_done ? FontWeight.w600 : FontWeight.normal),
                      ),
                    ),
                  ],
                ),
              ),
            if (!_done) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _note ?? items[_current].instruction,
                  key: const ValueKey('preflight-instruction'),
                  style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
                ),
              ),
              const SizedBox(height: 6),
              Text('SocialSave carries on by itself when it\'s done.', style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        if (!_done && items[_current].alt != null)
          TextButton(
            key: const ValueKey('preflight-alt'),
            onPressed: () async {
              final note = await items[_current].alt!();
              if (mounted && note != null) setState(() => _note = note);
              unawaited(_advance());
            },
            child: Text(items[_current].altLabel ?? 'Other way'),
          ),
        if (!_done)
          TextButton(
            key: const ValueKey('preflight-recheck'),
            onPressed: () => unawaited(_advance()),
            child: const Text('I turned it on'),
          ),
        if (!_done)
          FilledButton(
            key: const ValueKey('preflight-open'),
            onPressed: () => unawaited(_fix(_current)),
            child: const Text('Open again'),
          ),
      ],
    );
  }
}

Future<String?> _askPermission(Permission p, String name) async {
  final st = await p.request();
  if (st.isGranted) return null;
  if (st.isPermanentlyDenied || st.isRestricted) {
    await HotspotShare.openSettings('app');
    return 'Open Permissions › turn on "$name" for SocialSave, then come back.';
  }
  return 'Tap Allow when Android asks for "$name". Tap "Open again" to ask once more.';
}

Future<int> _sdk() async => ((await HotspotShare.status())['sdk'] as int?) ?? 0;

PreflightItem _permItem(int sdk) => sdk >= 33
    ? PreflightItem(
        label: 'Allow "Nearby devices"',
        instruction: 'Tap Allow so SocialSave can open and join Wi-Fi hotspots.',
        check: () => Permission.nearbyWifiDevices.isGranted,
        fix: () => _askPermission(Permission.nearbyWifiDevices, 'Nearby devices'),
      )
    : PreflightItem(
        label: 'Allow Location permission',
        instruction: 'Tap Allow. Android needs it for Wi-Fi hotspots on this version (SocialSave doesn\'t track you).',
        check: () => Permission.locationWhenInUse.isGranted,
        fix: () => _askPermission(Permission.locationWhenInUse, 'Location'),
      );

PreflightItem _locationItem() => PreflightItem(
      label: 'Location turned on',
      instruction: 'Turn on Location, then come back.',
      check: () async => (await HotspotShare.status())['locationOn'] == true,
      fix: () async {
        await HotspotShare.openSettings('location');
        return null;
      },
    );

/// Readiness for the sending side of Hotspot share. The last item is only
/// true when a hotspot is really on (SocialSave's own hotspot started, or
/// the phone's Mobile Hotspot is enabled and has its address).
Future<List<PreflightItem>> hotspotSenderItems() async {
  if (Plat.isWindows) {
    return [
      PreflightItem(
        label: 'Mobile hotspot available',
        instruction: 'Turn on your hotspot first. The other device joins your PC through it, and the QR code only appears once it is on. Switch on Mobile hotspot in the Settings window that opened, then come back.',
        check: () async {
          final s = await PcHotspot.run('status');
          return s['state'] == 'On' || PcHotspot.blockMessage(s) == null;
        },
        fix: () async {
          final block = PcHotspot.blockMessage(await PcHotspot.run('status'));
          await HotspotShare.openSettings(block != null && block.contains('online') ? 'wifi' : 'hotspot');
          return block == null ? null : '$block\nThen come back: SocialSave carries on by itself.';
        },
      ),
    ];
  }
  final sdk = await _sdk();
  return [
    _permItem(sdk),
    if (sdk < 33) _locationItem(),
    PreflightItem(
      label: 'Hotspot ready',
      instruction: 'Starting a private hotspot for sharing... This takes a few seconds. If your phone asks for permission, tap Allow.',
      check: () async {
        final ready = await HotspotShare.hotspotReady();
        debugPrint('[hotspot-gate] hotspot ready=$ready');
        return ready;
      },
      fix: () async {
        // 1. SocialSave's own local-only hotspot first (no need to touch the
        // phone's regular hotspot). 2. Only if that fails: ask the user.
        String why;
        try {
          debugPrint('[hotspot-gate] starting own local-only hotspot');
          await HotspotShare.start().timeout(const Duration(seconds: 12));
          debugPrint('[hotspot-gate] own hotspot started');
          return 'Hotspot is starting...';
        } on HotspotError catch (e) {
          why = e.message;
        } on TimeoutException {
          why = 'it took too long to start';
        } catch (e) {
          why = '$e';
        }
        if (await HotspotShare.hotspotReady()) return null;
        final opened = await HotspotShare.openSettings('hotspot');
        debugPrint('[hotspot-gate] own hotspot failed ($why) -> opened tethering settings: $opened');
        return 'Turn on your hotspot first. SocialSave could not start its own hotspot ($why), so please switch on your phone\'s hotspot in the Settings screen that just opened. The QR code appears by itself as soon as it is on. Use "I turned it on" to check again.';
      },
    ),
  ];
}

/// Readiness for receiving (scan the sender's QR and join its hotspot).
Future<List<PreflightItem>> receiverItems() async {
  if (!HotspotShare.supported || Plat.isWindows) return const [];
  final sdk = await _sdk();
  return [
    PreflightItem(
      label: 'Wi-Fi turned on',
      instruction: 'Turn on Wi-Fi, then come back.',
      check: () async => (await HotspotShare.status())['wifiOn'] == true,
      fix: () async {
        await HotspotShare.openSettings('wifi');
        return null;
      },
    ),
    _permItem(sdk),
    if (sdk < 33) _locationItem(),
    PreflightItem(
      label: 'Allow camera (to scan the QR)',
      instruction: 'Tap Allow so SocialSave can scan the sender\'s QR.',
      check: () => Permission.camera.isGranted,
      fix: () => _askPermission(Permission.camera, 'Camera'),
    ),
  ];
}
