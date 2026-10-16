import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:social_save/web/web_library.dart';

Future<void> openInAppPlayer(
  BuildContext context,
  DownloadRecord record,
) async {
  final path = record.localPath;
  if (kIsWeb) {
    // Web: plays the copy stored in this browser (IndexedDB).
    await openWebPlayer(context, null, [record], 0);
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
  if (kIsWeb) {
    return context.push(
      '/player',
      extra: WebPlayerArgs(
        items: [WebPlayItem(title: session.title, url: session.networkUrl, sourceUrl: session.referer)],
      ),
    );
  }
  return context.push('/player', extra: session);
}
