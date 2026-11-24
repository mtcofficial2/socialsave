import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:social_save/core/diagnostics/quiet_log.dart';
import 'package:social_save/features/chat/chat_alerts.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/features/chat/chat_history.dart';
import 'package:social_save/features/chat/chat_image_store.dart';
import 'package:social_save/features/chat/chat_live.dart';

/// Sends one message that is still waiting on this device (text, voice,
/// song, photo, file or clip). Used by the open chat and by [ChatOutbox].
Future<ChatMessage> chatSendPending(
  ChatApi api,
  String threadId,
  ChatMessage message,
) async {
  final bytes = message.localBytes;
  final kind = message.pendingKind;
  if (kind == 'voice' && bytes != null) {
    return api.sendVoice(threadId, bytes, message.voiceMs, reply: message.reply);
  }
  if (kind == 'song' && bytes != null) {
    return api.sendSong(
      threadId,
      bytes,
      name: message.songName.isEmpty ? message.text : message.songName,
      milliseconds: message.songMs,
      reply: message.reply,
    );
  }
  if (kind == 'photo' && bytes != null) {
    final caption = message.text == 'Photo' ? '' : message.text;
    final outgoing = await api.sendPhoto(
      threadId,
      bytes,
      caption: caption,
      reply: message.reply,
    );
    await chatKeepSentPhoto(threadId, outgoing, bytes);
    return outgoing.message;
  }
  if ((kind == 'file' || kind == 'clip') && bytes != null) {
    return api.sendFile(
      threadId,
      bytes,
      name: message.fileName.isEmpty ? 'file' : message.fileName,
      caption: message.text,
      reply: message.reply,
      clip: message.isClip,
    );
  }
  return api.send(threadId, message.text, reply: message.reply);
}

/// Keeps a sent photo on this device and, when the server holds it for the
/// live line, sends the picture over it.
Future<void> chatKeepSentPhoto(
  String threadId,
  ChatOutgoing outgoing,
  Uint8List bytes,
) async {
  final photoId = outgoing.message.photo;
  if (photoId.isEmpty) return;
  await ChatImageStore.save(photoId, bytes);
  await ChatImageStore.keep(threadId, photoId);
  if (outgoing.held) {
    ChatLive.instance.sendBinary(encodeChatPhotoFrame(threadId, photoId, bytes));
  }
}

/// Sends messages written offline in chats that are not on screen, so they
/// go out in the background once the network is back (like WhatsApp). The
/// open chat sends its own queue.
class ChatOutbox {
  ChatOutbox._();

  static bool _running = false;

  /// The chat whose queue is being sent right now, so the open chat does
  /// not send the same message at the same moment.
  static String sending = '';

  static Future<void> flush(ChatApi api) async {
    if (_running) return;
    _running = true;
    try {
      final me = await ChatSession.username();
      if (me.isEmpty) return;
      final threads = await ChatHistory.queuedThreads(me);
      for (final threadId in threads) {
        if (threadId == ChatAlerts.openThread) continue;
        final keepGoing = await _flushThread(api, me, threadId);
        if (!keepGoing) break;
      }
    } catch (e) {
      logQuiet('chat_outbox', e);
    } finally {
      sending = '';
      _running = false;
    }
  }

  /// Returns false when the network is still down, so other chats wait too.
  static Future<bool> _flushThread(ChatApi api, String me, String threadId) async {
    final log = await ChatHistory.log(me, threadId);
    if (log == null) return true;
    final queued = chatResendOrder(log.messages);
    if (queued.isEmpty) return true;
    sending = threadId;
    var messages = List<ChatMessage>.of(log.messages);
    var online = true;
    try {
      // A send that got through just as the line dropped is already on the
      // server: match it instead of sending it twice.
      List<ChatMessage> server = const [];
      try {
        final sync = await api.messages(threadId, log.newest > 50 ? log.newest - 50 : 0);
        server = sync.messages;
      } catch (error) {
        if (chatIsOffline(error)) return false;
      }
      for (final message in queued) {
        if (threadId == ChatAlerts.openThread) break;
        ChatMessage? delivered;
        if (chatAlreadyDelivered(message, server, me: me)) {
          messages = [
            for (final item in messages)
              if (item.id != message.id) item,
          ];
          continue;
        }
        try {
          delivered = await chatSendPending(api, threadId, message);
        } catch (error) {
          if (chatIsOffline(error)) {
            online = false;
            break;
          }
          messages = [
            for (final item in messages)
              if (item.id == message.id) item.copyWith(status: 'failed') else item,
          ];
          continue;
        }
        messages = [
          for (final item in messages)
            if (item.id != message.id) item,
          if (delivered.id > 0) delivered.withQuoteFrom(message),
        ];
      }
    } finally {
      await ChatHistory.saveLog(
        username: me,
        threadId: threadId,
        messages: messages,
        delivered: log.delivered,
        read: log.read,
        seen: log.seen,
        photoRev: log.photoRev,
      );
      sending = '';
    }
    return online;
  }
}
