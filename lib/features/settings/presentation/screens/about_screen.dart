import 'package:flutter/material.dart';
import 'package:social_save/shared/widgets/page_layout.dart';
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
        padding: pagePadding(context, top: 8, maxWidth: 720),
        children: [
          const Center(child: AppLogo(size: 72)),
          const SizedBox(height: 16),
          Text(
            AppConstants.appName,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                'Version ${AppConstants.appVersion}',
                style: TextStyle(
                  color: scheme.onSecondaryContainer,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'SocialSave is a download manager for public video URLs that you are allowed to save. '
            'This app never bypasses DRM, logins, or private posts. It only calls your backend, '
            'which must use official or otherwise permitted APIs.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface,
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
