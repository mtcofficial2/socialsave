import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/security/token_seal.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_history.dart';
import 'package:social_save/features/chat/chat_live.dart';
import 'package:social_save/features/library/nearby_service.dart';
import 'package:social_save/features/library/vault_service.dart';

const _a = '11111111-1111-4111-8111-111111111111';
const _b = '22222222-2222-4222-8222-222222222222';

VaultItem _item(String id, {String title = 'Clip'}) => VaultItem(
      id: id,
      title: title,
      fileName: '$id.mp4',
      bytes: 3,
      addedAt: DateTime(2026, 1, 1),
    );

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('ss129');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('vault PIN lockout', () {
    test('waits grow after repeated wrong PINs and nothing is wiped', () {
      expect(VaultService.lockoutFor(4), Duration.zero);
      expect(VaultService.lockoutFor(5), const Duration(seconds: 30));
      expect(VaultService.lockoutFor(6), const Duration(minutes: 1));
      expect(VaultService.lockoutFor(8), const Duration(minutes: 15));
      expect(VaultService.lockoutFor(40), const Duration(hours: 1));
    });

    test('a locked vault refuses even the right PIN until the wait ends', () async {
      SharedPreferences.setMockInitialValues({});
      final vault = VaultService(await SharedPreferences.getInstance());
      await vault.setPin('1234');
      final start = DateTime(2026, 11, 24, 10);
      for (var i = 0; i < 4; i++) {
        final r = await vault.checkPin('0000', now: start);
        expect(r.ok, isFalse);
        expect(r.wait, Duration.zero);
      }
      final fifth = await vault.checkPin('0000', now: start);
      expect(fifth.wait, const Duration(seconds: 30));
      final early = await vault.checkPin('1234', now: start.add(const Duration(seconds: 10)));
      expect(early.ok, isFalse);
      expect(early.wait, greaterThan(Duration.zero));
      final later = await vault.checkPin('1234', now: start.add(const Duration(seconds: 31)));
      expect(later.ok, isTrue);
      expect(vault.lockedFor(start.add(const Duration(seconds: 31))), Duration.zero);
      expect(vault.verifyPin('1234'), isTrue);
    });
  });

  group('vault list safety', () {
    test('a damaged list falls back to the backup, then to the files', () async {
      final dir = Directory(p.join(root.path, 'vault'))..createSync();
      File(p.join(dir.path, '$_a.mp4')).writeAsBytesSync([1, 2, 3]);
      File(p.join(dir.path, '$_b.mp4')).writeAsBytesSync([4, 5, 6]);
      await writeVaultIndex(dir, [_item(_a, title: 'First')]);
      await writeVaultIndex(dir, [_item(_a, title: 'First'), _item(_b, title: 'Second')]);

      File(p.join(dir.path, 'index.json')).writeAsStringSync('{broken');
      final fromBackup = await readVaultIndex(dir);
      expect(fromBackup.map((e) => e.id).toSet(), {_a, _b});
      expect(fromBackup.firstWhere((e) => e.id == _a).title, 'First');

      File(p.join(dir.path, 'index.json')).deleteSync();
      File(p.join(dir.path, 'index.json.bak')).deleteSync();
      final rebuilt = await readVaultIndex(dir);
      expect(rebuilt.map((e) => e.id).toSet(), {_a, _b});
    });

    test('moving the vault copies, checks, then removes old files', () async {
      final oldDir = Directory(p.join(root.path, 'Documents', 'vault'))..createSync(recursive: true);
      final newDir = Directory(p.join(root.path, 'AppData', 'vault'));
      File(p.join(oldDir.path, '$_a.mp4')).writeAsBytesSync(List.filled(5000, 7));
      File(p.join(oldDir.path, '$_b.mp4')).writeAsBytesSync([9, 9, 9]);
      File(p.join(oldDir.path, 'my notes.txt')).writeAsStringSync('keep me');
      await writeVaultIndex(oldDir, [_item(_a, title: 'Holiday'), _item(_b)]);

      final moved = await migrateVaultFolder(oldDir, newDir);

      expect(moved, 2);
      expect(File(p.join(newDir.path, '$_a.mp4')).readAsBytesSync(), List.filled(5000, 7));
      expect(File(p.join(newDir.path, '$_b.mp4')).readAsBytesSync(), [9, 9, 9]);
      final listed = await readVaultIndex(newDir);
      expect(listed.firstWhere((e) => e.id == _a).title, 'Holiday');
      expect(File(p.join(oldDir.path, '$_a.mp4')).existsSync(), isFalse);
      // Files the vault did not make are left alone.
      expect(File(p.join(oldDir.path, 'my notes.txt')).readAsStringSync(), 'keep me');
      // Running it again changes nothing.
      expect(await migrateVaultFolder(oldDir, newDir), 0);
      expect((await readVaultIndex(newDir)).length, 2);
    });

    test('a video missing from the old folder stays listed there', () async {
      final oldDir = Directory(p.join(root.path, 'old'))..createSync();
      final newDir = Directory(p.join(root.path, 'new'));
      File(p.join(oldDir.path, '$_a.mp4')).writeAsBytesSync([1]);
      await writeVaultIndex(oldDir, [_item(_a), _item(_b)]);
      expect(await migrateVaultFolder(oldDir, newDir), 1);
      final rest = jsonDecode(File(p.join(oldDir.path, 'index.json')).readAsStringSync()) as List;
      expect(rest.single['id'], _b);
    });
  });

  test('nearby pauses in the background only when idle', () {
    expect(NearbyService.shouldPauseInBackground(busy: false, sessionActive: false), isTrue);
    expect(NearbyService.shouldPauseInBackground(busy: true, sessionActive: false), isFalse);
    expect(NearbyService.shouldPauseInBackground(busy: false, sessionActive: true), isFalse);
  });

  test('the live chat connection pings often enough to notice a dead link', () {
    expect(chatLivePingInterval.inSeconds, inInclusiveRange(15, 30));
  });

  test('threads with queued messages are found for the outbox', () async {
    ChatHistory.rootOverride = root;
    ChatHistory.debugReset();
    addTearDown(() {
      ChatHistory.rootOverride = null;
      ChatHistory.debugReset();
    });
    ChatMessage msg(int id, String status) => ChatMessage(
          id: id,
          from: 'me',
          name: 'me',
          text: 'hi',
          links: const [],
          at: DateTime(2026, 11, 24),
          status: status,
        );
    await ChatHistory.saveLog(
        username: 'me', threadId: 't1', messages: [msg(-1, 'queued')], delivered: 0, read: 0, photoRev: 0);
    await ChatHistory.saveLog(
        username: 'me', threadId: 't2', messages: [msg(5, '')], delivered: 0, read: 0, photoRev: 0);
    expect(await ChatHistory.queuedThreads('me'), ['t1']);
  });

  test('the chat sign-in survives the move to sealed storage', () async {
    SharedPreferences.setMockInitialValues({chatTokenKey: 'tok-abc'});
    expect(await ChatSession.token(), 'tok-abc');
    final prefs = await SharedPreferences.getInstance();
    if (TokenSeal.supported) {
      expect(prefs.getString(chatTokenKey), isNull);
      expect(prefs.getString(chatSealedTokenKey), isNot(contains('tok-abc')));
    } else {
      expect(prefs.getString(chatTokenKey), 'tok-abc');
    }
    expect(await ChatSession.token(), 'tok-abc');
    await ChatSession.save(token: 'tok-new', username: 'me', contact: '');
    expect(await ChatSession.token(), 'tok-new');
    await ChatSession.clear();
    expect(await ChatSession.token(), isNull);
  });
}
