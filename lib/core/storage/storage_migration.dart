import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/storage/vault_recovery.dart';
import 'package:social_save/features/downloads/domain/repositories/downloads_repository.dart';
import 'package:social_save/features/library/vault_service.dart';

/// 1.0.13: videos used to be saved twice on Android (the app's private
/// folder plus a public copy in Download/SocialSave). This keeps one public
/// copy: identical private copies are deleted, private-only files are moved
/// to Download/SocialSave, and download records are repointed. The vault is
/// never touched (it lives elsewhere and stays private).
class StorageMigration {
  StorageMigration._();

  static const _doneKey = 'socialsave_single_copy_v1';
  static const _media = MethodChannel('socialsave/media');
  static const publicRoot = '/storage/emulated/0/Download/SocialSave';
  static bool _running = false;

  static Future<void> run(DownloadsRepository repo, {VaultService? vault}) async {
    if (!Platform.isAndroid || _running) return;
    _running = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_doneKey) == true) return;
      final ext = await getDownloadsDirectory();
      if (ext == null) return;
      final private = Directory(p.join(ext.path, 'SocialSave'));
      final public = Directory(publicRoot);
      await public.create(recursive: true);
      // Must be able to write publicly, or we'd have nowhere to keep files.
      final probe = File(p.join(public.path, '.socialsave_probe'));
      await probe.writeAsString('ok');
      await probe.delete();
      final moved = <String, String>{};
      var failures = 0;
      if (private.existsSync()) {
        final files = private.listSync(recursive: true).whereType<File>().toList();
        for (final f in files) {
          final rel = p.relative(f.path, from: private.path);
          if (rel.split('/').contains('vault')) continue;
          try {
            // 1.0.14: a leftover copy of a vault video must never go public.
            if (vault != null && await VaultRecovery.isVaultCopy(vault, f)) {
              await f.delete();
              continue;
            }
            final target = await _settle(f, p.join(public.path, rel));
            moved[f.path] = target;
          } catch (error) {
            failures++;
            debugPrint('migration: $rel failed: $error');
          }
        }
      }
      for (final record in await repo.getAll()) {
        final local = record.localPath;
        final to = local == null ? null : moved[local];
        if (to != null) await repo.upsert(record.copyWith(localPath: to));
      }
      if (failures == 0) await prefs.setBool(_doneKey, true);
      debugPrint('migration: ${moved.length} files settled, $failures failed');
    } catch (error) {
      debugPrint('migration skipped: $error');
    } finally {
      _running = false;
    }
  }

  /// Returns the public path that now holds [f]'s content.
  static Future<String> _settle(File f, String publicPath) async {
    final size = await f.length();
    final pub = File(publicPath);
    if (pub.existsSync() && await pub.length() == size) {
      await f.delete();
      return pub.path;
    }
    var target = publicPath;
    if (pub.existsSync()) {
      final base = p.basenameWithoutExtension(publicPath);
      final ext = p.extension(publicPath);
      for (var i = 1;; i++) {
        target = p.join(p.dirname(publicPath), '$base ($i)$ext');
        if (!File(target).existsSync()) break;
      }
    }
    await Directory(p.dirname(target)).create(recursive: true);
    try {
      await f.rename(target);
    } on FileSystemException {
      await f.copy(target);
      if (await File(target).length() != size) {
        await File(target).delete();
        throw const FileSystemException('copy incomplete');
      }
      await f.delete();
    }
    try {
      await _media.invokeMethod<void>('scanFile', {'path': target});
    } catch (_) {}
    return target;
  }
}
