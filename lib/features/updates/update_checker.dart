import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/features/updates/release_version.dart';
import 'package:url_launcher/url_launcher.dart';

const _releasesUrl = 'https://api.github.com/repos/mtcofficial2/socialsave/releases/latest';

/// Checks GitHub once when the app opens and asks for an install when a newer APK exists.
class UpdateChecker extends StatefulWidget {
  const UpdateChecker({super.key, required this.child});

  final Widget child;

  @override
  State<UpdateChecker> createState() => _UpdateCheckerState();
}

class _UpdateCheckerState extends State<UpdateChecker> {
  var _checked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    if (_checked || !mounted) return;
    _checked = true;
    try {
      final current = AppConstants.appVersion;
      final response = await Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
          headers: const {'Accept': 'application/vnd.github+json'},
        ),
      ).get<Map<String, dynamic>>(_releasesUrl);
      final data = response.data;
      if (data == null || !mounted) return;
      final assets = data['assets'];
      String? apk;
      if (assets is List) {
        for (final asset in assets) {
          if (asset is Map && asset['name'] == 'SocialSave.apk') {
            apk = asset['browser_download_url'] as String?;
          }
        }
      }
      final update = newerRelease(
        current: current,
        tag: '${data['tag_name'] ?? ''}',
        apkUrl: apk,
        pageUrl: data['html_url'] as String?,
      );
      if (update == null || !mounted) return;
      final host = context;
      await showDialog<void>(
        context: host,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Update available'),
          content: Text(
            'SocialSave ${update.version} is ready. You have $current.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(dialogContext);
                final opened = await launchUrl(
                  update.downloadUrl,
                  mode: LaunchMode.externalApplication,
                );
                if (!opened && host.mounted) {
                  ScaffoldMessenger.of(host).showSnackBar(
                    const SnackBar(content: Text('Could not open the update download.')),
                  );
                }
              },
              child: const Text('Update'),
            ),
          ],
        ),
      );
    } catch (_) {
      // A failed check should not block the app.
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
