import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/platform/media_events.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';

const _kEnabled = 'bgdetect.enabled';
const _kBubble = 'bgdetect.bubble';
const _kBubbleOpacity = 'bgdetect.bubbleOpacity';

/// On/off switch and setup for the floating download bubble and the
/// Download copied link tile. Sharing a link into the app stays separate.
class BackgroundDetectScreen extends ConsumerStatefulWidget {
  const BackgroundDetectScreen({super.key});

  @override
  ConsumerState<BackgroundDetectScreen> createState() => _BackgroundDetectScreenState();
}

class _BackgroundDetectScreenState extends ConsumerState<BackgroundDetectScreen> with WidgetsBindingObserver {
  bool _enabled = true;
  int _opacity = 45;
  bool _overlay = false;
  bool _bubbleRunning = false;
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    if (!p.containsKey(_kEnabled)) await p.setBool(_kEnabled, true);
    _enabled = p.getBool(_kEnabled) ?? true;
    _opacity = (p.getInt(_kBubbleOpacity) ?? 45).clamp(20, 80);
    await _refresh();
  }

  Future<void> _refresh() async {
    try {
      final r = await MediaEvents.channel.invokeMethod<Map<dynamic, dynamic>>('bgStatus');
      if (!mounted || r == null) return;
      setState(() {
        _overlay = r['overlay'] == true;
        _bubbleRunning = r['bubble'] == true;
      });
    } catch (_) {
      if (mounted) setState(() {});
    }
  }

  Future<void> _call(String m) async {
    try {
      await MediaEvents.channel.invokeMethod<void>(m);
    } catch (_) {}
  }

  Future<void> _setEnabled(bool v) async {
    setState(() => _enabled = v);
    await _prefs?.setBool(_kEnabled, v);
  }

  Future<void> _setBubble(bool v) async {
    if (v && !_overlay) {
      await _call('openOverlaySettings');
      return;
    }
    await _prefs?.setBool(_kBubble, v);
    await _call(v ? 'bubbleStart' : 'bubbleStop');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurface.withValues(alpha: 0.6);
    final offerOn = ref.watch(settingsControllerProvider.select((s) => s.offerCopiedLinks));
    final active = _enabled && offerOn && _overlay && _bubbleRunning;

    Widget dot(bool on) => Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(shape: BoxShape.circle, color: on ? const Color(0xFF3DDC84) : scheme.onSurface.withValues(alpha: 0.25)),
        );

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            Row(children: [
              IconButton(onPressed: () => context.pop(), icon: const Icon(Icons.arrow_back_rounded)),
            ]),
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 4, 4, 6),
              child: Text('Detect links in the background', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w400)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 18),
              child: Text(
                active
                    ? 'The bubble is on. Copy a video link, tap the bubble, and SocialSave offers to download it.'
                    : 'Copy a video link, then tap the floating bubble or the Download copied link tile. You can also share the link into SocialSave.',
                style: TextStyle(fontSize: 14, height: 1.4, color: muted),
              ),
            ),
            SwitchListTile(
              key: const ValueKey('bgdetect-switch'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              title: const Text('Detect links in the background', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(offerOn ? 'Turn off any time. This does not remove the permission.' : 'Needs "Offer to download copied links" in Settings', style: TextStyle(color: muted, fontSize: 13)),
              value: _enabled,
              onChanged: _setEnabled,
            ),
            if (!offerOn)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => ref.read(settingsControllerProvider.notifier).setOfferCopiedLinks(true),
                    child: const Text('Turn on "Offer to download copied links"'),
                  ),
                ),
              ),
            const SizedBox(height: 6),
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(24)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('What this can see', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(
                  'Tapping the bubble or the Download copied link tile reads the link you just copied, only to check whether it is a public video from TikTok, Instagram, YouTube, Facebook, X, Reddit or Pinterest. It does not watch your screen. Nothing is stored or sent until you tap Download.',
                  style: TextStyle(fontSize: 13, height: 1.45, color: muted),
                ),
              ]),
            ),
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: scheme.onSurface.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(24)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  dot(_overlay && _bubbleRunning),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('Floating bubble', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
                  Text(_overlay && _bubbleRunning ? 'On' : 'Off', style: TextStyle(fontSize: 12.5, color: muted)),
                ]),
                const SizedBox(height: 8),
                Text(
                  'Android hides the clipboard from background apps, so a copy is not noticed on its own. A small bubble stays on screen: copy a link in any app, tap the bubble, and the Download card appears. It pulses when you open a Copy menu. Needs "Display over other apps". You can also add the "Download copied link" tile to Quick Settings for the same one-tap action.',
                  style: TextStyle(fontSize: 13, height: 1.4, color: muted),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonal(
                    onPressed: () => _overlay ? _setBubble(!_bubbleRunning) : _call('openOverlaySettings'),
                    style: FilledButton.styleFrom(shape: const StadiumBorder(), minimumSize: const Size(0, 44)),
                    child: Text(_overlay ? (_bubbleRunning ? 'Turn bubble off' : 'Turn bubble on') : 'Allow display over other apps'),
                  ),
                ),
              ]),
            ),
            if (_overlay && _bubbleRunning)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Row(children: [
                  const Text('Bubble opacity', style: TextStyle(fontSize: 13.5)),
                  Expanded(
                    child: Slider(
                      value: _opacity.toDouble(),
                      min: 20,
                      max: 80,
                      divisions: 12,
                      label: '$_opacity%',
                      onChanged: (v) => setState(() => _opacity = v.round()),
                      onChangeEnd: (v) async {
                        await _prefs?.setInt(_kBubbleOpacity, v.round());
                        await _call('bubbleStyle');
                      },
                    ),
                  ),
                  Text('$_opacity%', style: TextStyle(fontSize: 12.5, color: muted)),
                ]),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Sharing a link into SocialSave, and the Download copied link quick-settings tile, work without the bubble.',
                style: TextStyle(fontSize: 12.5, height: 1.4, color: muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
