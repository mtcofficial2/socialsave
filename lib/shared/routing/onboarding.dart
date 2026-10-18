import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';

const _doneKey = 'socialsave_onboarding_done_v1';

/// Shows the first-run welcome once, on top of the app.
class OnboardingGate extends StatefulWidget {
  const OnboardingGate({super.key, required this.child});
  final Widget child;

  @override
  State<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends State<OnboardingGate> {
  @override
  void initState() {
    super.initState();
    unawaited(_maybeShow());
  }

  Future<void> _maybeShow() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_doneKey) == true) return;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => const OnboardingScreen()),
    );
    await prefs.setBool(_doneKey, true);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _page = PageController();
  int _index = 0;

  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_doneKey, true);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _allow() async {
    try {
      if (Plat.isAndroid) {
        await [Permission.notification, Permission.nearbyWifiDevices, Permission.videos, Permission.storage].request();
      } else {
        await Permission.notification.request();
      }
    } catch (_) {}
    if (mounted) unawaited(_page.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOut));
  }

  Widget _slide(IconData icon, String title, String body, {Widget? extra}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 84, color: scheme.primary),
              const SizedBox(height: 24),
              Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              Text(body, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
              if (extra != null) ...[const SizedBox(height: 20), extra],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(settingsControllerProvider.select((s) => s.themeMode));
    final last = _index == 2;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: _finish, child: const Text('Skip')),
            ),
            Expanded(
              child: PageView(
                controller: _page,
                onPageChanged: (i) => setState(() => _index = i),
                children: [
                  _slide(
                    Icons.lock_open_rounded,
                    'Allow a few things',
                    'Nearby devices lets SocialSave find your other phone or PC. Storage lets it save and send your videos and files. Notifications tell you when something arrives. You can change these any time in Settings.',
                    extra: FilledButton(onPressed: _allow, child: const Text('Allow')),
                  ),
                  _slide(
                    Icons.swap_horiz_rounded,
                    'Share in two taps',
                    'Open SocialSave on both devices on the same Wi-Fi. Tap Send / Receive, then tap the device you see. No Wi-Fi? Use Fast connect: one device shows a QR, the other scans it.',
                  ),
                  _slide(
                    Icons.palette_rounded,
                    'Pick your look',
                    'Choose how SocialSave looks. You can change this later in Settings.',
                    extra: SegmentedButton<ThemeMode>(
                      segments: const [
                        ButtonSegment(value: ThemeMode.system, label: Text('Auto'), icon: Icon(Icons.brightness_auto_rounded)),
                        ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_rounded)),
                        ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_rounded)),
                      ],
                      selected: {mode},
                      onSelectionChanged: (s) => ref.read(settingsControllerProvider.notifier).setThemeMode(s.first),
                    ),
                  ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < 3; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.all(4),
                    width: i == _index ? 22 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: i == _index ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
                  onPressed: last ? _finish : () => _page.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
                  child: Text(last ? 'Get started' : 'Next'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}