import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:social_save/features/chat/chat_thread_screen.dart';

/// The person behind a username. Another person's phone or email is never shown.
Future<void> showChatProfile(
  BuildContext context, {
  required String username,
  String contact = '',
}) {
  final name = username.replaceFirst(RegExp(r'^@'), '').trim();
  final mine = contact.trim().isNotEmpty;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ChatAvatar(name: name.isEmpty ? '?' : name, size: 96),
              const SizedBox(height: 16),
              Text(
                name.isEmpty ? 'Chat' : name,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.3),
              ),
              const SizedBox(height: 6),
              Text(
                mine ? 'This is your Social Save profile' : 'Social Save profile',
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
              ),
              if (mine) ...[
                const SizedBox(height: 8),
                Text(
                  'Registered with ${contact.trim()}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
                ),
              ],
              const SizedBox(height: 18),
              FilledButton.tonalIcon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: '@$name'));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Username copied')));
                },
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Copy username'),
              ),
            ],
          ),
        ),
      );
    },
  );
}
