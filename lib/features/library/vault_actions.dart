import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/downloads/presentation/providers/downloads_controller.dart';
import 'package:social_save/features/library/presentation/library_screen.dart';

Future<bool> moveDownloadToVault(
  BuildContext context,
  WidgetRef ref,
  DownloadRecord record, {
  bool deletePublic = true,
}) async {
  final path = record.localPath;
  if (path == null || path.isEmpty || !File(path).existsSync()) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The file is no longer on this device.')),
      );
    }
    return false;
  }
  final unlocked = await ensureVaultUnlocked(context, ref);
  if (!unlocked || !context.mounted) return false;
  await ref.read(vaultServiceProvider).importFile(
        sourcePath: path,
        title: record.title,
      );
  if (deletePublic) {
    await ref.read(downloadsControllerProvider.notifier).delete(
          record.id,
          deleteFile: true,
        );
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          deletePublic
              ? 'Moved to vault. Unlock Library with your PIN to watch it.'
              : 'Copied to vault.',
        ),
      ),
    );
  }
  return true;
}
