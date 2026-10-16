import 'dart:async';
import 'package:social_save/core/platform/plat.dart';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/platform/media_events.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/routing/app_router.dart';

const _videoChannel = MethodChannel('socialsave/media');

/// A video path passed on the command line (`--play file` or Open with).
String? openedVideoArgument(List<String> args) {
  final flagged = args.indexOf('--play');
  if (flagged >= 0 && flagged + 1 < args.length) return args[flagged + 1];
  for (final arg in args) {
    if (arg.startsWith('-')) continue;
    final ext = p.extension(arg).replaceFirst('.', '').toLowerCase();
    if (AppConstants.allowedVideoExtensions.contains(ext)) return arg;
  }
  return null;
}

String _lastPlayed = '';
DateTime _lastPlayedAt = DateTime.fromMillisecondsSinceEpoch(0);

/// Opens a local video in the in-app player. A second call for the same
/// file within a moment (startup plus the native callback) is ignored.
Future<void> playOpenedVideo(String path, {String title = ''}) async {
  if (path.isEmpty || !File(path).existsSync()) return;
  final now = DateTime.now();
  if (path == _lastPlayed && now.difference(_lastPlayedAt) < const Duration(seconds: 2)) {
    return;
  }
  _lastPlayed = path;
  _lastPlayedAt = now;
  final name = title.trim().isEmpty ? p.basename(path) : title.trim();
  await appRouter.push(
    '/player',
    extra: PlayerSession(
      title: name,
      platform: SocialPlatform.direct,
      filePath: path,
    ),
  );
}

/// Phone: a video shared or opened from another app.
void listenForOpenedVideos() {
  MediaEvents.on('openedVideo', (args) async {
    await _playPayload(args);
    try {
      await _videoChannel.invokeMethod<void>('consumeOpenedVideo');
    } catch (_) {}
  });
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      final payload = await _videoChannel.invokeMethod<dynamic>('consumeOpenedVideo');
      await _playPayload(payload);
    } catch (_) {}
  });
}

Future<void> _playPayload(dynamic args) async {
  if (args is! Map) return;
  await playOpenedVideo('${args['path'] ?? ''}', title: '${args['title'] ?? ''}');
}

/// PC: list SocialSave under Open with for the video types it plays.
/// Does not change the default player.
Future<void> registerWindowsVideoPlayer() async {
  if (!Plat.isWindows) return;
  final exe = Platform.resolvedExecutable;
  final command = '"$exe" "%1"';
  final extensions = [for (final ext in AppConstants.allowedVideoExtensions) '.$ext'];
  try {
    await _reg([
      'add',
      r'HKCU\Software\Classes\SocialSave.Video',
      '/ve',
      '/d',
      'SocialSave',
      '/f',
    ]);
    await _reg([
      'add',
      r'HKCU\Software\Classes\SocialSave.Video\DefaultIcon',
      '/ve',
      '/d',
      '"$exe",0',
      '/f',
    ]);
    await _reg([
      'add',
      r'HKCU\Software\Classes\SocialSave.Video\shell\open\command',
      '/ve',
      '/d',
      command,
      '/f',
    ]);
    await _reg([
      'add',
      r'HKCU\Software\Classes\Applications\SocialSave.exe\shell\open\command',
      '/ve',
      '/d',
      command,
      '/f',
    ]);
    await _reg([
      'add',
      r'HKCU\Software\Classes\Applications\SocialSave.exe',
      '/v',
      'FriendlyAppName',
      '/d',
      'SocialSave',
      '/f',
    ]);
    await _reg([
      'add',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\SocialSave.exe',
      '/ve',
      '/d',
      exe,
      '/f',
    ]);
    await _reg([
      'add',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\SocialSave.exe',
      '/v',
      'Path',
      '/d',
      p.dirname(exe),
      '/f',
    ]);
    for (final ext in extensions) {
      await _reg([
        'add',
        r'HKCU\Software\Classes\Applications\SocialSave.exe\SupportedTypes',
        '/v',
        ext,
        '/d',
        '',
        '/f',
      ]);
      // FileExts and SystemFileAssociations add an Open with choice.
      // HKCU\Software\Classes\.ext is left alone so the default player stays.
      await _regNone(
        'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\$ext\\OpenWithProgids',
      );
      await _regNone(
        'HKCU\\Software\\Classes\\SystemFileAssociations\\$ext\\OpenWithProgids',
      );
      await _addOpenWithList(ext);
    }
    await _regNone(
      r'HKCU\Software\Classes\SystemFileAssociations\video\OpenWithProgids',
    );
    await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      "Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class SsAssoc { [DllImport(\"shell32.dll\")] public static extern void SHChangeNotify(int e, uint f, System.IntPtr a, System.IntPtr b); }'; [SsAssoc]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)",
    ]);
  } catch (_) {}
}

Future<void> _addOpenWithList(String ext) async {
  final key = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\$ext\\OpenWithList';
  final query = await Process.run('reg', ['query', key]);
  final text = '${query.stdout}'.replaceAll('\r', '');
  final mru = RegExp(r'MRUList\s+REG_SZ\s+(\S+)').firstMatch(text)?.group(1) ?? '';
  var letter = '';
  for (final match in RegExp(r'^\s+([a-z])\s+REG_SZ\s+(.+)$', multiLine: true).allMatches(text)) {
    if ((match.group(2) ?? '').trim().toLowerCase() == 'socialsave.exe') {
      letter = match.group(1) ?? '';
      break;
    }
  }
  if (letter.isEmpty) {
    final used = RegExp(r'^\s+([a-z])\s+REG_', multiLine: true)
        .allMatches(text)
        .map((match) => match.group(1))
        .whereType<String>()
        .toSet();
    for (final ch in 'abcdefghijklmnopqrstuvwxyz'.split('')) {
      if (!mru.contains(ch) && !used.contains(ch)) {
        letter = ch;
        break;
      }
    }
    if (letter.isEmpty) return;
    await _reg(['add', key, '/v', letter, '/d', 'SocialSave.exe', '/f']);
  }
  final rest = mru.replaceAll(letter, '');
  if (mru.startsWith(letter) && rest.length == mru.length - 1) return;
  await _reg(['add', key, '/v', 'MRUList', '/d', '$letter$rest', '/f']);
}

Future<void> _reg(List<String> args) async {
  await Process.run('reg', args);
}

/// Open with lists a ProgID only when the value is REG_NONE, same as VLC.
Future<void> _regNone(String key) async {
  await _reg([
    'add',
    key,
    '/v',
    'SocialSave.Video',
    '/t',
    'REG_NONE',
    '/f',
  ]);
}
