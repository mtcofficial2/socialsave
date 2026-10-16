// Pieces of the browser build that stand in for phone/PC-only features.
import 'package:flutter/material.dart';
import 'package:social_save/web/web_relay.dart';
import 'package:social_save/web/web_saver.dart';

const _apkUrl =
    'https://github.com/mtcofficial2/socialsave/releases/latest/download/SocialSave.apk';
// Newest release that has a Windows build attached.
const _windowsZipUrl =
    'https://github.com/mtcofficial2/socialsave/releases/download/v1.0.23/SocialSave-Windows-1.0.23.zip';

/// Shown on the web where a phone/PC-only feature sits in the apps
/// (Nearby share, the Vault, device folders).
class WebAppsCard extends StatelessWidget {
  const WebAppsCard({
    super.key,
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: scheme.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    'App only',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              style: TextStyle(fontSize: 13, height: 1.4, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () => webOpenTab(_apkUrl),
                    icon: const Icon(Icons.android_rounded, size: 18),
                    label: const Text('Android app'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => webOpenTab(_windowsZipUrl),
                    icon: const Icon(Icons.desktop_windows_rounded, size: 18),
                    label: const Text('PC app'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Nearby share on the web: a browser cannot find devices on the Wi-Fi or a
/// USB cable, so it points to the apps.
class WebNearbyCard extends StatelessWidget {
  const WebNearbyCard({super.key});

  @override
  Widget build(BuildContext context) => const WebRelayCard();
}

/// Lets non-widget code (e.g. the downloads controller) show a snackbar.
final webMessengerKey = GlobalKey<ScaffoldMessengerState>();

void webToast(String text) {
  webMessengerKey.currentState?.showSnackBar(SnackBar(content: Text(text)));
}
