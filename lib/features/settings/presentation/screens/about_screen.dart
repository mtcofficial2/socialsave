import 'package:flutter/material.dart';
import 'package:social_save/core/config/env_config.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/shared/widgets/app_logo.dart';
import 'package:social_save/shared/widgets/compliance_notice.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Center(child: AppLogo(size: 72, showWordmark: true)),
          const SizedBox(height: 16),
          Text(
            'Version ${AppConstants.appVersion}',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            'SocialSave is a download manager for public video URLs that you are allowed to save. '
            'The mobile app never talks to TikTok, Instagram, YouTube, or other platforms directly. '
            'It only calls your backend, which must use official or otherwise permitted APIs.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          const ComplianceNotice(),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Backend'),
            subtitle: Text(EnvConfig.apiBaseUrl),
          ),
        ],
      ),
    );
  }
}
