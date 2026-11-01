import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:social_save/core/config/env_config.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_image_store.dart';
import 'package:social_save/features/chat/chat_live.dart';

Future<void> runChatSocket(ChatLive live, int epoch) async {
  var delay = 1;
  final photoTries = <String, int>{};
  if (epoch != live.epoch) return;
  live.deliveredPhoto = (id) {
    photoTries.remove(id);
    unawaited(ChatImageStore.clear(id));
  };
  live.resendPhotos = () {
    photoTries.clear();
    unawaited(ChatImageStore.flush(live.sendBinary));
  };
  live.resendPhoto = (id) {
    final n = photoTries[id] ?? 0;
    if (n >= 40) return;
    photoTries[id] = n + 1;
    unawaited(ChatImageStore.sendPending(id, live.sendBinary));
  };
  while (!live.stopped && epoch == live.epoch) {
    final token = await ChatSession.token();
    if (token == null || token.isEmpty) {
      await Future<void>.delayed(const Duration(seconds: 2));
      continue;
    }
    WebSocket? socket;
    try {
      final base = Uri.parse(chatApiBaseUrl());
      final ws = base.replace(
        scheme: base.scheme == 'https' ? 'wss' : 'ws',
        path: '/api/v1/chat/live',
      );
      final headers = <String, dynamic>{'X-Chat-Token': token};
      if (EnvConfig.hasApiKey) {
        headers['Authorization'] = 'Bearer ${EnvConfig.apiKey}';
      }
      socket = await WebSocket.connect(
        ws.toString(),
        headers: headers,
      ).timeout(const Duration(seconds: 20));
      if (live.stopped || epoch != live.epoch) {
        await socket.close();
        return;
      }
      final current = socket;
      live.attach(
        text: (text) => current.add(text),
        binary: (bytes) => current.add(bytes),
        close: () {
          unawaited(current.close());
        },
      );
      delay = 1;
      unawaited(ChatImageStore.flush((frame) => current.add(frame)));
      current.listen((data) {
        if (data is String) {
          live.onText(data);
          return;
        }
        if (data is Uint8List) {
          unawaited(ChatImageStore.take(data, (text) => current.add(text)));
          return;
        }
        if (data is List<int>) {
          unawaited(
            ChatImageStore.take(
              Uint8List.fromList(data),
              (text) => current.add(text),
            ),
          );
        }
      }, onError: (_) {});
      await current.done;
    } catch (_) {
      // The next attempt starts after a short wait. The poll still carries messages.
    }
    if (epoch != live.epoch) return;
    live.detach();
    if (live.stopped || epoch != live.epoch) return;
    await Future<void>.delayed(Duration(seconds: delay));
    if (delay < 8) delay *= 2;
  }
}
