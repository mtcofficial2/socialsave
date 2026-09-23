import 'package:flutter/material.dart';
import 'package:social_save/shared/widgets/glass.dart';

class ComplianceNotice extends StatelessWidget {
  const ComplianceNotice({super.key, this.compact = false, this.danger = false});

  final bool compact;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (danger) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.block, color: scheme.error, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'This link looks private, login-walled, or DRM-protected. SocialSave only archives public, allowed media.',
                  style: TextStyle(color: scheme.onErrorContainer, fontSize: 12.5, height: 1.4),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Glass(
      borderRadius: 22,
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.gavel, size: 18, color: scheme.onSecondaryContainer),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Compliance Notice',
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    compact
                        ? 'SocialSave only downloads public, uncopyrighted, or permissible creative commons media. Private accounts and DRM streams are strictly restricted.'
                        : 'You are responsible for the content you download. SocialSave only works with publicly accessible media that you are allowed to save. It will not bypass DRM, logins, private accounts, paywalls, or other access controls.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.35,
                          fontSize: 12,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
