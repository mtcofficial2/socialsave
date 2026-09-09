import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/features/home/presentation/providers/home_controller.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/widgets/error_banner.dart';
import 'package:social_save/shared/widgets/platform_badge.dart';

class UrlInputCard extends ConsumerStatefulWidget {
  const UrlInputCard({
    super.key,
    required this.onAnalyze,
  });

  final Future<void> Function() onAnalyze;

  @override
  ConsumerState<UrlInputCard> createState() => _UrlInputCardState();
}

class _UrlInputCardState extends ConsumerState<UrlInputCard> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ref.read(homeControllerProvider).url,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(homeControllerProvider);
    final controller = ref.read(homeControllerProvider.notifier);
    final platform = state.detectedPlatform;

    ref.listen<String>(homeControllerProvider.select((value) => value.url), (
      previous,
      next,
    ) {
      if (_controller.text != next) {
        _controller.value = TextEditingValue(
          text: next,
          selection: TextSelection.collapsed(offset: next.length),
        );
      }
    });

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Paste a public video URL',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Paste a TikTok, YouTube, Instagram, Facebook, X, Reddit, Pinterest, or direct video link.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('url-input'),
              controller: _controller,
              onChanged: controller.setUrl,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              autocorrect: false,
              enableSuggestions: false,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: 'https://',
                prefixIcon: const Icon(Icons.link),
                suffixIcon: state.url.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        onPressed: () => controller.setUrl(''),
                        icon: const Icon(Icons.close),
                      ),
              ),
              onSubmitted: (_) => widget.onAnalyze(),
            ),
            if (platform != SocialPlatform.unknown) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: PlatformBadge(platform: platform),
              ),
            ],
            if (state.error != null) ...[
              const SizedBox(height: 12),
              ErrorBanner(message: state.error!),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('paste-button'),
                    onPressed: state.isAnalyzing
                        ? null
                        : controller.pasteFromClipboard,
                    icon: const Icon(Icons.content_paste_rounded),
                    label: const Text('Paste'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    key: const Key('analyze-button'),
                    onPressed: state.isAnalyzing ? null : widget.onAnalyze,
                    icon: state.isAnalyzing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search_rounded),
                    label: Text(state.isAnalyzing ? 'Analyzing…' : 'Analyze'),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed:
                    state.isAnalyzing ? null : controller.useSampleUrl,
                child: const Text('Try a sample public video'),
              ),
            ),
            Text(
              'Sample: ${AppConstants.samplePublicVideoUrl.split('/').last}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
