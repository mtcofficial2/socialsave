import 'package:social_save/core/errors/exceptions.dart';
import 'package:flutter/material.dart';
import 'package:social_save/core/engine/phone_engine.dart';
import 'package:social_save/shared/widgets/glass.dart';

/// Android: "Download on this phone (no server)". Off by default.
class PhoneEngineSection extends StatefulWidget {
  const PhoneEngineSection({super.key, required this.title});

  final Widget title;

  @override
  State<PhoneEngineSection> createState() => _PhoneEngineSectionState();
}

class _PhoneEngineSectionState extends State<PhoneEngineSection> {
  Map<String, dynamic> _status = const {};
  bool _busy = false;
  String? _note;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    await PhoneEngine.isEnabled();
    final status = await PhoneEngine.status();
    if (mounted) setState(() => _status = status);
  }

  Future<void> _toggle(bool on) async {
    if (!on) {
      await PhoneEngine.setEnabled(false);
      if (mounted) setState(() => _note = null);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _SetupDialog(),
    );
    if (ok == true) await PhoneEngine.setEnabled(true);
    await _refresh();
  }

  Future<void> _update() async {
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      final r = await PhoneEngine.update();
      _note = r['status'] == 'DONE'
          ? 'yt-dlp updated to ${r['version']}.'
          : 'yt-dlp is up to date (${r['version']}).';
    } catch (e) {
      _note = '$e'.replaceFirst('On-phone engine: ', 'Update failed: ');
    }
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final supported = _status['supported'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.title,
        GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ValueListenableBuilder<bool>(
              valueListenable: PhoneEngine.enabled,
              builder: (context, on, _) => Column(
                key: const ValueKey('phone-engine-section'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.phone_android_rounded, color: scheme.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Download on this phone (no server)',
                                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                            Text(
                              !supported && _status.isNotEmpty
                                  ? 'Needs a 64-bit ARM phone. Links use the SocialSave server.'
                                  : on
                                      ? 'Links are analyzed and saved here with yt-dlp and ffmpeg. The server is not used.'
                                      : 'Off: the SocialSave server prepares videos. On: everything runs on this phone.',
                              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        key: const ValueKey('phone-engine-switch'),
                        value: on,
                        onChanged: supported ? _toggle : null,
                      ),
                    ],
                  ),
                  if (on) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'yt-dlp ${_status['version'] ?? '…'} · updates daily',
                            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _busy ? null : _update,
                          icon: _busy
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.system_update_alt_rounded, size: 18),
                          label: const Text('Update yt-dlp'),
                        ),
                      ],
                    ),
                    const _YouTubeSignIn(),
                  ],
                  if (_note != null)
                    Text(_note!, style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// First enable: unpack the engine, then check for a newer yt-dlp.
class _SetupDialog extends StatefulWidget {
  const _SetupDialog();

  @override
  State<_SetupDialog> createState() => _SetupDialogState();
}

class _SetupDialogState extends State<_SetupDialog> {
  String _step = 'Setting up the engine on this phone…';
  double? _value;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      await PhoneEngine.prepare();
      if (!mounted) return;
      setState(() {
        _step = 'Checking for the latest yt-dlp…';
        _value = 0.6;
      });
      try {
        await PhoneEngine.update();
      } catch (_) {
        // Offline: the bundled yt-dlp still works; it updates later.
      }
      if (!mounted) return;
      setState(() {
        _step = 'Ready';
        _value = 1;
      });
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = (e is AppException ? e.message : '$e').replaceFirst('On-phone engine: ', '').trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Download on this phone'),
      content: _error != null
          ? Text('SocialSave could not set up downloading on this phone, so the switch stays off and saves keep using the SocialSave server. Try again later, or update the app.\n\nDetails: $_error')
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_step),
                const SizedBox(height: 14),
                LinearProgressIndicator(value: _value),
              ],
            ),
      actions: [
        if (_error != null)
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Close')),
      ],
    );
  }
}

/// "Sign in to YouTube" / "Sign out": cookies for the on-phone engine when
/// YouTube asks the phone to prove it isn't a bot.
class _YouTubeSignIn extends StatefulWidget {
  const _YouTubeSignIn();

  @override
  State<_YouTubeSignIn> createState() => _YouTubeSignInState();
}

class _YouTubeSignInState extends State<_YouTubeSignIn> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PhoneEngine.refreshYouTubeSignIn();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) PhoneEngine.refreshYouTubeSignIn();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<bool>(
      valueListenable: PhoneEngine.youTubeSignedIn,
      builder: (context, signedIn, _) => Row(
        children: [
          Expanded(
            child: Text(
              signedIn
                  ? 'Signed in to YouTube on this phone'
                  : "YouTube: sign in if it asks this phone to prove it isn't a bot",
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ),
          TextButton.icon(
            key: const ValueKey('settings-youtube-sign-in'),
            onPressed: signedIn ? PhoneEngine.signOutYouTube : PhoneEngine.signInYouTube,
            icon: Icon(signedIn ? Icons.logout_rounded : Icons.login_rounded, size: 18),
            label: Text(signedIn ? 'Sign out' : 'Sign in to YouTube'),
          ),
        ],
      ),
    );
  }
}
