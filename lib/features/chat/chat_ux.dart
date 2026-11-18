import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:social_save/features/chat/chat_api.dart';

/// Messages that sit inside a photo set and should not get their own bubble.
///
/// A set is consecutive photos from the same person, about a minute apart.
/// The first can carry the caption. A later photo with its own caption or a
/// reply quote stays on its own.
Set<int> chatPhotoFollowers(List<ChatMessage> messages) {
  final hidden = <int>{};
  ChatMessage? previous;
  for (final message in messages) {
    if (!message.isPhoto) {
      previous = null;
      continue;
    }
    final bare = message.text.trim().isEmpty || message.text.trim() == 'Photo';
    final close = previous != null &&
        message.name == previous.name &&
        message.replyText.isEmpty &&
        bare &&
        message.at.difference(previous.at).inSeconds.abs() <= 60;
    if (close) {
      hidden.add(message.id);
    }
    previous = message;
  }
  return hidden;
}

/// The lead photo plus the followers that belong in its set.
List<ChatMessage> chatPhotoAlbum(List<ChatMessage> messages, ChatMessage lead) {
  if (!lead.isPhoto) return const [];
  final album = <ChatMessage>[lead];
  var seen = false;
  ChatMessage? previous;
  for (final message in messages) {
    if (!seen) {
      if (message.id == lead.id) {
        seen = true;
        previous = message;
      }
      continue;
    }
    if (!message.isPhoto) break;
    final bare = message.text.trim().isEmpty || message.text.trim() == 'Photo';
    final close = previous != null &&
        message.name == previous.name &&
        message.replyText.isEmpty &&
        bare &&
        message.at.difference(previous.at).inSeconds.abs() <= 60;
    if (!close) break;
    album.add(message);
    previous = message;
  }
  return album;
}

/// Message ids whose text, quote, song, or file name contains [query].
List<int> chatSearchHitIds(List<ChatMessage> messages, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const [];
  return [
    for (final message in messages)
      if (message.text.toLowerCase().contains(needle) ||
          message.replyText.toLowerCase().contains(needle) ||
          message.songName.toLowerCase().contains(needle) ||
          message.fileName.toLowerCase().contains(needle))
        message.id,
  ];
}

/// The partial @name being typed at [caret], or null when @ is not open.
String? chatMentionQuery(String text, int caret) {
  if (caret < 0 || caret > text.length) return null;
  final match = RegExp(r'(^|[\s\n])@([A-Za-z0-9_]{0,20})$').firstMatch(text.substring(0, caret));
  return match?.group(2);
}

class ChatMediaEntry {
  const ChatMediaEntry({required this.kind, required this.messageId, required this.label, required this.ref});

  /// photo, voice, or link.
  final String kind;
  final int messageId;
  final String label;
  final String ref;
}

/// Photos, voice notes, and links already loaded in this chat.
List<ChatMediaEntry> chatMediaEntries(List<ChatMessage> messages) {
  final items = <ChatMediaEntry>[];
  for (final message in messages) {
    if (message.isPhoto && message.photo.isNotEmpty) {
      items.add(ChatMediaEntry(
        kind: 'photo',
        messageId: message.id,
        label: message.text.trim().isEmpty ? 'Photo' : message.text.trim(),
        ref: message.photo,
      ));
    } else if (message.isVoice) {
      items.add(ChatMediaEntry(
        kind: 'voice',
        messageId: message.id,
        label: 'Voice message',
        ref: message.voice,
      ));
    }
    for (final link in message.links) {
      items.add(ChatMediaEntry(kind: 'link', messageId: message.id, label: link, ref: link));
    }
  }
  return items;
}

/// A failed outgoing send that is not older than the server preview.
bool chatHasFailedSend(List<ChatMessage> messages, String me, DateTime? lastAt) {
  for (final message in messages.reversed) {
    if (message.name != me || message.id >= 0 || message.status != 'failed') continue;
    if (lastAt != null && message.at.isBefore(lastAt)) continue;
    return true;
  }
  return false;
}

/// Pinned chats first. Newer [lastAt] wins inside each group.
int chatPinCompare(ChatThreadSummary a, ChatThreadSummary b) {
  if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
  final at = a.lastAt?.millisecondsSinceEpoch ?? 0;
  final bt = b.lastAt?.millisecondsSinceEpoch ?? 0;
  if (at != bt) return bt.compareTo(at);
  return a.id.compareTo(b.id);
}

String chatByteLabel(int bytes) {
  if (bytes < 0) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  final mb = bytes / (1024 * 1024);
  final text = mb >= 10 ? mb.round().toString() : mb.toStringAsFixed(1);
  return '$text MB';
}

const chatDocExtensions = {
  'pdf', 'txt', 'csv', 'rtf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'zip',
};

const chatClipExtensions = {'mp4', 'mov', 'webm', 'm4v', '3gp'};

const chatDocMaxBytes = 8 * 1024 * 1024;
const chatClipMaxBytes = 12 * 1024 * 1024;
const chatPhotoSetMax = 10;

String chatFileExtension(String name) {
  final slash = name.replaceAll('\\', '/');
  final base = slash.contains('/') ? slash.substring(slash.lastIndexOf('/') + 1) : slash;
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return '';
  return base.substring(dot + 1).toLowerCase();
}

bool chatIsDocumentName(String name) => chatDocExtensions.contains(chatFileExtension(name));

bool chatIsClipName(String name) => chatClipExtensions.contains(chatFileExtension(name));

/// Text that can be forwarded. Photos, voice, songs, files, and rich cards cannot.
bool chatCanForward(ChatMessage message) {
  if (message.text.trim().isEmpty) return false;
  if (message.isPhoto || message.isVoice || message.isSong || message.isFile) return false;
  if (message.isPoll || message.isCard || message.isPlace || message.isCall) return false;
  return true;
}

/// Applies a local pin and unread mark onto a list row.
ChatThreadSummary chatWithListFlags(
  ChatThreadSummary item, {
  required bool pinned,
  required bool marked,
}) {
  final unread = marked && item.unread < 1 ? 1 : item.unread;
  if (item.pinned == pinned && item.marked == marked && item.unread == unread) return item;
  return item.copyWith(pinned: pinned, marked: marked, unread: unread);
}

/// Right swipe on a message, for a finger only. A mouse click does not count.
class ChatSwipeReply extends StatefulWidget {
  const ChatSwipeReply({super.key, required this.child, required this.onReply});

  final Widget child;
  final VoidCallback onReply;

  @override
  State<ChatSwipeReply> createState() => _ChatSwipeReplyState();
}

class _ChatSwipeReplyState extends State<ChatSwipeReply> {
  double _drag = 0;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      supportedDevices: const <PointerDeviceKind>{
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
      },
      onHorizontalDragStart: (_) => _dragging = true,
      onHorizontalDragUpdate: (details) {
        setState(() {
          _dragging = true;
          _drag = (_drag + details.delta.dx).clamp(0, 72);
        });
      },
      onHorizontalDragEnd: (_) {
        final reply = _drag > 48;
        setState(() {
          _dragging = false;
          _drag = 0;
        });
        if (reply) widget.onReply();
      },
      onHorizontalDragCancel: () {
        if (_drag == 0 && !_dragging) return;
        setState(() {
          _dragging = false;
          _drag = 0;
        });
      },
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          if (_drag > 8)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(Icons.reply_rounded, color: ChatUiTokensBridge.brand),
            ),
          AnimatedContainer(
            duration: _dragging ? Duration.zero : const Duration(milliseconds: 140),
            transform: Matrix4.translationValues(_drag, 0, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

/// Brand color without importing the whole chat UI file from a low widget.
class ChatUiTokensBridge {
  static const brand = Color(0xFF25D366);
}

/// Looks at the photos and types one caption before they are sent.
Future<String?> showChatPhotoPreview(BuildContext context, List<Uint8List> photos) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => _PhotoPreview(photos: photos)),
  );
}

class _PhotoPreview extends StatefulWidget {
  const _PhotoPreview({required this.photos});

  final List<Uint8List> photos;

  @override
  State<_PhotoPreview> createState() => _PhotoPreviewState();
}

class _PhotoPreviewState extends State<_PhotoPreview> {
  final TextEditingController _caption = TextEditingController();

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final many = widget.photos.length > 1;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(many ? '${widget.photos.length} photos' : 'Photo'),
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView(
              children: [
                for (final bytes in widget.photos)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Image.memory(bytes, fit: BoxFit.contain),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _caption,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: 'Caption',
                      hintStyle: TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Send',
                  onPressed: () => Navigator.pop(context, _caption.text.trim()),
                  icon: const Icon(Icons.send_rounded, color: Color(0xFF25D366)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Photos, voice notes, and links from the messages already loaded.
class ChatMediaPage extends StatelessWidget {
  const ChatMediaPage({
    super.key,
    required this.title,
    required this.messages,
    required this.onLink,
  });

  final String title;
  final List<ChatMessage> messages;
  final ValueChanged<String> onLink;

  @override
  Widget build(BuildContext context) {
    final items = chatMediaEntries(messages);
    final photos = [for (final item in items) if (item.kind == 'photo') item];
    final voices = [for (final item in items) if (item.kind == 'voice') item];
    final links = [for (final item in items) if (item.kind == 'link') item];
    return Scaffold(
      appBar: AppBar(title: Text(title.isEmpty ? 'Media' : title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Text(
            'Older messages may be missing. This list is what is already loaded.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.35),
          ),
          const SizedBox(height: 16),
          _MediaBlock(
            title: 'Photos',
            empty: 'No photos',
            children: [
              for (final item in photos)
                ListTile(
                  leading: const Icon(Icons.photo_outlined),
                  title: Text(item.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => _openPhoto(context, item.ref),
                ),
            ],
          ),
          _MediaBlock(
            title: 'Voice notes',
            empty: 'No voice notes',
            children: [
              for (final item in voices)
                ListTile(
                  leading: const Icon(Icons.mic_rounded),
                  title: Text(item.label),
                ),
            ],
          ),
          _MediaBlock(
            title: 'Links',
            empty: 'No links',
            children: [
              for (final item in links)
                ListTile(
                  leading: const Icon(Icons.link_rounded),
                  title: Text(item.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                  onTap: () => onLink(item.ref),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openPhoto(BuildContext context, String id) async {
    final bytes = await ChatApi().image(id);
    if (!context.mounted || bytes == null || bytes.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: InteractiveViewer(child: Image.memory(bytes, fit: BoxFit.contain)),
      ),
    );
  }
}

class _MediaBlock extends StatelessWidget {
  const _MediaBlock({required this.title, required this.empty, required this.children});

  final String title;
  final String empty;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        if (children.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(empty, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          )
        else
          ...children,
        const SizedBox(height: 8),
      ],
    );
  }
}

/// A document or short clip on a message.
class ChatFileCard extends StatelessWidget {
  const ChatFileCard({super.key, required this.message, required this.onOpen});

  final ChatMessage message;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final clip = message.isClip;
    final name = message.fileName.trim().isEmpty ? (clip ? 'Short clip' : 'Document') : message.fileName.trim();
    final size = message.fileSize > 0 ? chatByteLabel(message.fileSize) : '';
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Icon(clip ? Icons.play_circle_outline : Icons.description_outlined, size: 28),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    [clip ? 'Short clip' : 'Document', if (size.isNotEmpty) size].join(' · '),
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
