import 'package:flutter/material.dart';

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({
    super.key,
    required this.message,
    this.onRetry,
    this.onTryServer,
  });

  final String message;
  final VoidCallback? onRetry;

  /// Shown for on-phone engine errors: "Try with server".
  final VoidCallback? onTryServer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, color: scheme.error, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onErrorContainer,
                      height: 1.4,
                    ),
              ),
            ),
            if (onRetry != null || onTryServer != null)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (onRetry != null)
                    TextButton(onPressed: onRetry, child: const Text('Retry')),
                  if (onTryServer != null)
                    TextButton(
                      key: const ValueKey('try-with-server'),
                      onPressed: onTryServer,
                      child: const Text('Try with server'),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
