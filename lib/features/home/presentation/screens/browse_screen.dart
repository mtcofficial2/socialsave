import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/core/utils/platform_detector.dart';
import 'package:social_save/core/utils/set_link.dart';
import 'package:social_save/features/home/presentation/widgets/link_offer.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

const _sites = <(String, String)>[
  ('YouTube', 'https://m.youtube.com'),
  ('TikTok', 'https://www.tiktok.com'),
  ('Instagram', 'https://www.instagram.com'),
  ('Facebook', 'https://m.facebook.com'),
  ('X', 'https://x.com'),
  ('Reddit', 'https://www.reddit.com'),
  ('Pinterest', 'https://www.pinterest.com'),
];

/// True when [url] looks like a single supported video/post page.
bool isDownloadablePage(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return false;
  final p = const PlatformDetector().detect(url);
  const ok = {
    SocialPlatform.tiktok,
    SocialPlatform.instagram,
    SocialPlatform.facebook,
    SocialPlatform.x,
    SocialPlatform.youtube,
    SocialPlatform.reddit,
    SocialPlatform.pinterest,
  };
  if (!ok.contains(p)) return false;
  final path = uri.path;
  if (p == SocialPlatform.youtube) {
    return (path == '/watch' && uri.queryParameters.containsKey('v')) ||
        path.startsWith('/shorts/') ||
        uri.host.contains('youtu.be');
  }
  return path.length > 3 && path.split('/').where((s) => s.isNotEmpty).length >= 2;
}

String _toUrl(String input) {
  final t = input.trim();
  if (t.isEmpty) return '';
  if (RegExp(r'^https?://', caseSensitive: false).hasMatch(t)) return t;
  if (!t.contains(' ') && t.contains('.')) return 'https://$t';
  return 'https://www.google.com/search?q=${Uri.encodeQueryComponent(t)}';
}

class BrowseScreen extends StatefulWidget {
  const BrowseScreen({super.key, this.initialUrl});

  final String? initialUrl;

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  final _field = TextEditingController();
  final _focus = FocusNode();
  WebViewController? _web;
  String _url = '';
  bool _canBack = false;
  bool _canFwd = false;
  int _progress = 100;

  bool get _embedded => Plat.isAndroid;

  @override
  void initState() {
    super.initState();
    if (_embedded) {
      _web = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(NavigationDelegate(
          onProgress: (p) => mounted ? setState(() => _progress = p) : null,
          onUrlChange: (c) => _sync(c.url),
          onPageFinished: (u) => _sync(u),
        ));
    }
    final start = widget.initialUrl?.trim() ?? '';
    if (start.isNotEmpty) {
      _field.text = start;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_go(start));
      });
    }
  }

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _sync(String? u) async {
    final b = await _web?.canGoBack() ?? false;
    final f = await _web?.canGoForward() ?? false;
    if (!mounted) return;
    setState(() {
      if (u != null) {
        _url = u;
        if (!_focus.hasFocus) _field.text = u;
      }
      _canBack = b;
      _canFwd = f;
    });
  }

  Future<void> _go(String input) async {
    final url = _toUrl(input);
    if (url.isEmpty) return;
    _focus.unfocus();
    if (_embedded) {
      setState(() => _url = url);
      await _web!.loadRequest(Uri.parse(url));
    } else if (isDownloadablePage(url)) {
      await offerLink(url);
    } else {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final page = _embedded ? _url : _toUrl(_field.text);
    final set = isPublicSet(page);
    final canDl = set || isDownloadablePage(page);
    return PopScope(
      canPop: !(_embedded && _canBack),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _canBack) _web?.goBack();
      },
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Container(
            height: 42,
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(children: [
              Icon(Icons.search_rounded, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: const ValueKey('browse-url'),
                  controller: _field,
                  focusNode: _focus,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  style: const TextStyle(fontSize: 14),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true,
                    hintText: 'Search or paste a link',
                  ),
                  onTap: () => _field.selection = TextSelection(baseOffset: 0, extentOffset: _field.text.length),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: _go,
                ),
              ),
            ]),
          ),
          actions: [
            if (_embedded) ...[
              IconButton(
                tooltip: 'Back',
                onPressed: _canBack ? () => _web!.goBack() : null,
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              IconButton(
                tooltip: 'Forward',
                onPressed: _canFwd ? () => _web!.goForward() : null,
                icon: const Icon(Icons.arrow_forward_rounded),
              ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: () => _web!.reload(),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ],
          bottom: _embedded && _progress < 100
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(value: _progress / 100, minHeight: 2),
                )
              : null,
        ),
        body: Column(children: [
          SizedBox(
            height: 52,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: _sites.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) => ActionChip(
                key: ValueKey('site-${_sites[i].$1}'),
                label: Text(_sites[i].$1),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  _go(_sites[i].$2);
                },
              ),
            ),
          ),
          Expanded(
            child: _embedded
                ? (_url.isEmpty ? _Empty(scheme: scheme) : WebViewWidget(controller: _web!))
                : _Empty(scheme: scheme, desktop: true),
          ),
        ]),
        floatingActionButton: canDl
            ? FloatingActionButton.extended(
                key: const ValueKey('browse-download'),
                onPressed: () => offerLink(page),
                icon: const Icon(Icons.download_rounded),
                label: Text(set ? 'Save this set' : 'Download'),
              )
            : null,
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.scheme, this.desktop = false});
  final ColorScheme scheme;
  final bool desktop;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.public_rounded, size: 56, color: scheme.primary.withValues(alpha: 0.7)),
          const SizedBox(height: 16),
          Text('Browse and save', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            desktop
                ? 'Pick a site to open it in your browser, then paste a video link here to download it with your choice of quality.'
                : 'Open a site, find a video, and tap Download when it appears.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }
}