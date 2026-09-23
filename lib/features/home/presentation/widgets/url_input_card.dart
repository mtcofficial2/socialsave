import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/features/home/presentation/providers/home_controller.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/widgets/error_banner.dart';
import 'package:social_save/shared/widgets/platform_badge.dart';
import 'package:social_save/shared/widgets/glass.dart';
import 'package:social_save/shared/widgets/platform_logo.dart';

class UrlInputCard extends ConsumerStatefulWidget {
  const UrlInputCard({
    super.key,
    required this.onAnalyze,
    required this.onPaste,
  });

  final Future<void> Function() onAnalyze;
  final Future<void> Function() onPaste;

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
    final scheme = Theme.of(context).colorScheme;

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

    return GlassCard(
      blur: true,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    'Paste a public video URL',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 18,
                          height: 1.25,
                        ),
                  ),
                ),
                const SizedBox(width: 8),
                if (platform != SocialPlatform.unknown)
                  PlatformLogo(platform: platform, size: 28)
                else
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.link, size: 14, color: scheme.onSecondaryContainer),
                  ),
                if (platform != SocialPlatform.unknown) ...[
                  const SizedBox(width: 8),
                  PlatformBadge(platform: platform, compact: true),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Works with public videos from TikTok, Instagram, YouTube, X, Reddit, Facebook, Pinterest, a direct file, or another website.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.35,
                  ),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      platform == SocialPlatform.unknown
                          ? Icon(Icons.link, size: 20, color: scheme.primary)
                          : PlatformLogo(platform: platform, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          key: const Key('url-input'),
                          controller: _controller,
                          onChanged: controller.setUrl,
                          keyboardType: TextInputType.url,
                          textInputAction: TextInputAction.done,
                          autocorrect: false,
                          enableSuggestions: false,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                          decoration: const InputDecoration(
                            hintText: 'https://...',
                            isDense: true,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                            contentPadding: EdgeInsets.zero,
                          ),
                          onSubmitted: (_) => widget.onAnalyze(),
                        ),
                      ),
                      if (state.url.isNotEmpty)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          onPressed: () => controller.setUrl(''),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                    ],
                  ),
                  if (platform != SocialPlatform.unknown) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.check_circle, size: 14, color: scheme.primary),
                        const SizedBox(width: 4),
                        Text(
                          state.isAnalyzing
                              ? 'Extracting public metadata…'
                              : 'Public ${platform.displayName} detected',
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          state.isAnalyzing ? 'Working' : 'Ready',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (state.error != null) ...[
              const SizedBox(height: 12),
              ErrorBanner(
                message: state.error!,
                onRetry: state.url.isEmpty ? null : widget.onAnalyze,
              ),
            ],
            const SizedBox(height: 12),
            if (state.canPasteLink) ...[
              SizedBox(
                height: 52,
                child: FilledButton.icon(
                  key: const Key('paste-button'),
                  onPressed: state.isAnalyzing ? null : widget.onPaste,
                  icon: const Icon(Icons.content_paste_rounded),
                  label: Text(state.isAnalyzing ? 'Opening link…' : 'Paste link'),
                ),
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              height: 52,
              child: state.canPasteLink
                  ? FilledButton.tonalIcon(
                      key: const Key('analyze-button'),
                      onPressed: state.isAnalyzing ? null : widget.onAnalyze,
                      icon: const Icon(Icons.manage_search_rounded, size: 20),
                      label: Text(state.isAnalyzing ? 'Analyzing…' : 'Analyze Link'),
                    )
                  : FilledButton(
                      key: const Key('analyze-button'),
                      onPressed: state.isAnalyzing ? null : widget.onAnalyze,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (state.isAnalyzing)
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: scheme.onPrimary,
                              ),
                            )
                          else
                            const Icon(Icons.manage_search_rounded, size: 20),
                          const SizedBox(width: 8),
                          Text(state.isAnalyzing ? 'Analyzing…' : 'Analyze Link'),
                          if (!state.isAnalyzing) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.arrow_forward_rounded, size: 18),
                          ],
                        ],
                      ),
                    ),
            ),
            if (!state.canPasteLink) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 52,
                child: FilledButton.tonalIcon(
                  key: const Key('paste-button'),
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.surfaceContainerLow,
                    foregroundColor: scheme.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: state.isAnalyzing ? null : widget.onPaste,
                  icon: const Icon(Icons.content_paste_rounded),
                  label: const Text('Paste link'),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: state.isAnalyzing ? null : controller.useSampleUrl,
                child: const Text('⚡  Try a sample public video'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
