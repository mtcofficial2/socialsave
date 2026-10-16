import 'dart:io';
import 'package:social_save/core/platform/plat.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/features/downloads/domain/repositories/downloads_repository.dart';
import 'package:social_save/features/library/vault_service.dart';

/// 1.0.14: puts vault videos that showed up in the gallery back where they
/// belong.
///
/// Before 1.0.13 every download existed twice on Android (a private copy in
/// Android/data/... and a public one in Download/SocialSave). "Move to vault"
/// removed only one of the two, so the other copy survived. The 1.0.13
/// single-copy migration then found those private-only leftovers and moved
/// them into Download/SocialSave, which made vault videos appear in the
/// gallery and Library again.
///
/// For every vault item this looks in the public SocialSave folders for a
/// file with the same content. If the vault copy is intact the public copy is
/// a duplicate and is removed (and dropped from MediaStore). If the vault
/// copy is missing, the public file is copied into the vault, verified, and
/// only then removed. Nothing is deleted unless a verified vault copy exists.
class VaultRecovery {
  VaultRecovery._();

  static const _doneKey = 'socialsave_vault_recovery_v1';
  static const _media = MethodChannel('socialsave/media');
  static const roots = [
    '/storage/emulated/0/Download/SocialSave',
    '/storage/emulated/0/Movies/SocialSave',
  ];
  static bool _running = false;

  /// Result of the last run, for logs/tests.
  static String lastReport = '';

  static Future<void> run(VaultService vault, DownloadsRepository repo) async {
    if (!Plat.isAndroid || _running) return;
    _running = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_doneKey) == true) return;
      final items = await vault.list();
      if (items.isEmpty) {
        await prefs.setBool(_doneKey, true);
        return;
      }
      final public = <File>[];
      for (final root in roots) {
        final dir = Directory(root);
        if (!dir.existsSync()) continue;
        public.addAll(dir.listSync(recursive: true).whereType<File>());
      }
      final bySize = <int, List<File>>{};
      for (final f in public) {
        try {
          bySize.putIfAbsent(f.lengthSync(), () => []).add(f);
        } catch (_) {}
      }
      var removed = 0, restored = 0, failures = 0;
      final gone = <String>{};
      for (final item in items) {
        final vf = await vault.fileFor(item);
        final hasVault = vf.existsSync();
        final size = hasVault ? vf.lengthSync() : item.bytes;
        if (size <= 0) continue;
        final candidates = (bySize[size] ?? []).where((f) => !gone.contains(f.path)).toList();
        if (candidates.isEmpty) continue;
        try {
          if (hasVault) {
            for (final c in candidates) {
              if (await sameContent(vf, c)) {
                if (await _removePublic(c)) {
                  gone.add(c.path);
                  removed++;
                } else {
                  failures++;
                }
              }
            }
          } else if (candidates.length == 1) {
            final c = candidates.single;
            await c.copy(vf.path);
            if (vf.lengthSync() == size && await sameContent(vf, c)) {
              restored++;
              if (await _removePublic(c)) {
                gone.add(c.path);
                removed++;
              } else {
                failures++;
              }
            } else {
              await vf.delete();
              failures++;
            }
          }
        } catch (error) {
          failures++;
          debugPrint('vault recovery: ${item.id} failed: $error');
        }
      }
      if (gone.isNotEmpty) {
        for (final record in await repo.getAll()) {
          if (gone.contains(record.localPath)) await repo.delete(record.id);
        }
      }
      if (failures == 0) await prefs.setBool(_doneKey, true);
      lastReport = 'vault ${items.length}, public copies removed $removed, '
          'restored into vault $restored, failed $failures';
      debugPrint('vault recovery: $lastReport');
    } catch (error) {
      debugPrint('vault recovery skipped: $error');
    } finally {
      _running = false;
    }
  }

  static Future<bool> _removePublic(File f) async {
    try {
      await f.delete();
    } catch (_) {}
    if (f.existsSync()) {
      try {
        await _media.invokeMethod<int>('deleteMedia', {
          'items': [
            {'id': null, 'path': f.path, 'uri': null},
          ],
        });
      } catch (_) {}
    }
    try {
      await _media.invokeMethod<void>('scanFile', {'path': f.path});
    } catch (_) {}
    return !f.existsSync();
  }

  /// Byte-for-byte comparison, 1 MB at a time.
  static Future<bool> sameContent(File a, File b) async {
    if (p.equals(a.path, b.path)) return true;
    final la = await a.length(), lb = await b.length();
    if (la != lb) return false;
    final ra = await a.open(), rb = await b.open();
    try {
      const chunk = 1 << 20;
      while (true) {
        final x = await ra.read(chunk);
        final y = await rb.read(chunk);
        if (x.length != y.length) return false;
        if (x.isEmpty) return true;
        if (!listEquals(x, y)) return false;
      }
    } finally {
      await ra.close();
      await rb.close();
    }
  }

  /// Used by the storage migration: true if [f] is a copy of a vault video.
  static Future<bool> isVaultCopy(VaultService vault, File f) async {
    final size = f.lengthSync();
    for (final item in await vault.list()) {
      final vf = await vault.fileFor(item);
      if (vf.existsSync() && vf.lengthSync() == size && await sameContent(vf, f)) return true;
    }
    return false;
  }
}
