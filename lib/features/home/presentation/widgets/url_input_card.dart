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

    final ready = platform != SocialPlatform.unknown;
    final emphasizePaste = state.canPasteLink && state.url.trim().isEmpty;
    return GlassCard(
      blur: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Paste a link',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                fontSize: 18,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 10),
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: ready
                      ? scheme.primary.withValues(alpha: 0.45)
                      : scheme.outlineVariant,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
                child: Row(
                  children: [
                    ready
                        ? PlatformLogo(platform: platform, size: 20)
                        : Icon(
                            Icons.link_rounded,
                            size: 20,
                            color: scheme.primary,
                          ),
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
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                        decoration: const InputDecoration(
                          hintText: 'https://...',
                          isDense: true,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          contentPadding: EdgeInsets.symmetric(vertical: 12),
                        ),
                        onSubmitted: (_) => widget.onAnalyze(),
                      ),
                    ),
                    if (state.url.isNotEmpty)
                      IconButton(
                        tooltip: 'Clear',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => controller.setUrl(''),
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                  ],
                ),
              ),
            ),
            if (ready) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  PlatformBadge(platform: platform, compact: true),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      state.isAnalyzing ? 'Opening this link…' : 'Public video',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (state.canPasteLink) ...[
              const SizedBox(height: 8),
              Text(
                'A link is ready to paste.',
                style: TextStyle(
                  color: scheme.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (state.error != null) ...[
              const SizedBox(height: 10),
              ErrorBanner(
                message: state.error!,
                onRetry: state.url.isEmpty ? null : widget.onAnalyze,
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _pasteButton(state, emphasizePaste)),
                const SizedBox(width: 8),
                Expanded(child: _analyzeButton(state, scheme, emphasizePaste)),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                ),
                onPressed: state.isAnalyzing ? null : controller.useSampleUrl,
                child: const Text('Try a sample public video'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pasteButton(HomeState state, bool emphasizePaste) {
    final style = FilledButton.styleFrom(
      minimumSize: const Size(0, 44),
      visualDensity: VisualDensity.compact,
    );
    final onPressed = state.isAnalyzing ? null : widget.onPaste;
    const icon = Icon(Icons.content_paste_rounded, size: 18);
    final label = Text(
      state.isAnalyzing && state.canPasteLink ? 'Opening…' : 'Paste link',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (emphasizePaste) {
      return FilledButton.icon(
        key: const Key('paste-button'),
        style: style,
        onPressed: onPressed,
        icon: icon,
        label: label,
      );
    }
    return FilledButton.tonalIcon(
      key: const Key('paste-button'),
      style: style,
      onPressed: onPressed,
      icon: icon,
      label: label,
    );
  }

  Widget _analyzeButton(
    HomeState state,
    ColorScheme scheme,
    bool emphasizePaste,
  ) {
    final style = FilledButton.styleFrom(
      minimumSize: const Size(0, 44),
      visualDensity: VisualDensity.compact,
    );
    final onPressed = state.isAnalyzing ? null : widget.onAnalyze;
    final icon = state.isAnalyzing
        ? SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: emphasizePaste
                  ? scheme.onSecondaryContainer
                  : scheme.onPrimary,
            ),
          )
        : const Icon(Icons.arrow_forward_rounded, size: 18);
    final label = Text(
      state.isAnalyzing ? 'Analyzing…' : 'Analyze Link',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (emphasizePaste) {
      return FilledButton.tonalIcon(
        key: const Key('analyze-button'),
        style: style,
        onPressed: onPressed,
        icon: icon,
        label: label,
      );
    }
    return FilledButton.icon(
      key: const Key('analyze-button'),
      style: style,
      onPressed: onPressed,
      icon: icon,
      label: label,
    );
  }
}
