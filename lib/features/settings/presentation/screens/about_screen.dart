import 'package:flutter/material.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/shared/widgets/app_logo.dart';
import 'package:social_save/shared/widgets/compliance_notice.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Center(child: AppLogo(size: 72)),
          const SizedBox(height: 12),
          const Center(
            child: Text(
              AppConstants.appName,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Version ${AppConstants.appVersion}',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
          ),
          const SizedBox(height: 20),
          Text(
            'SocialSave is a download manager for public video URLs that you are allowed to save. '
            'This app never bypasses DRM, logins, or private posts. It only calls your backend, '
            'which must use official or otherwise permitted APIs.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.55,
                ),
          ),
          const SizedBox(height: 16),
          const ComplianceNotice(),
        ],
      ),
    );
  }
}
