import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:social_save/web/web_saver.dart';

Future<void> openInAppPlayer(
  BuildContext context,
  DownloadRecord record,
) async {
  final path = record.localPath;
  if (kIsWeb) {
    // Web: a video saved in this tab plays from its blob; after a reload the
    // file only lives in the browser's Downloads folder.
    if (path != null && (webCanPlay(path) || path.startsWith('http'))) {
      await context.push(
        '/player',
        extra: PlayerSession(
          title: record.title,
          platform: record.platform,
          networkUrl: path,
          thumbnailUrl: record.thumbnailUrl,
          author: record.author,
          referer: record.sourceUrl,
        ),
      );
    } else if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Saved to your browser\'s Downloads folder. Open it from there to watch.'),
        ),
      );
    }
    return;
  }
  if (path == null || path.isEmpty || !File(path).existsSync()) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The file is no longer on this device.')),
      );
    }
    return;
  }
  await context.push('/player', extra: PlayerSession.fromRecord(record));
}

Future<void> openPreviewPlayer(
  BuildContext context,
  PlayerSession session,
) {
  return context.push('/player', extra: session);
}
