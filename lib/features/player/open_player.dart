import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/player/player_session.dart';

Future<void> openInAppPlayer(
  BuildContext context,
  DownloadRecord record,
) async {
  final path = record.localPath;
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
