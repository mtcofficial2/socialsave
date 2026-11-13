import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/utils/open_link.dart';
import 'package:social_save/features/chat/chat_link.dart';
import 'package:social_save/features/chat/link_text.dart';

/// A status that contains a link. Tap opens the site. A video also offers Download.
class StatusLinkCard extends StatelessWidget {
  const StatusLinkCard({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final download = linkOffersDownload(url);
    return FutureBuilder<ChatLinkPreview?>(
      future: ChatLinkCards.fetch(url),
      builder: (context, snapshot) {
        final preview = snapshot.data;
        final title = preview?.title.trim() ?? '';
        final host = Uri.tryParse(url)?.host ?? url;
        return Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => openWebLink(url),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (preview != null && preview.image.isNotEmpty)
                  Image.network(
                    preview.image,
                    height: 140,
                    fit: BoxFit.cover,
                    cacheWidth: 640,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                  child: Text(
                    title.isEmpty ? host : title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF111B21),
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    host,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Color(0xFF667781), fontSize: 13),
                  ),
                ),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: () => openWebLink(url),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Open site'),
                    ),
                    if (download)
                      TextButton.icon(
                        onPressed: () => context.push('/preview', extra: url),
                        icon: const Icon(Icons.download_rounded),
                        label: const Text('Download'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
