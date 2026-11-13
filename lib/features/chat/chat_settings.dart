import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_prefs.dart';
import 'package:social_save/features/chat/chat_services.dart';
import 'package:social_save/features/chat/chat_ui.dart';
import 'package:social_save/shared/widgets/page_layout.dart';

/// Account and chat controls. One quiet page, reached from the Settings tab.
class ChatSettingsPage extends StatefulWidget {
  const ChatSettingsPage({
    super.key,
    required this.username,
    required this.contact,
    required this.avatar,
    required this.admin,
    required this.onProfile,
    required this.onNewGroup,
    required this.onJoin,
    required this.onArchivedChats,
    required this.onArchivedGroups,
    required this.onBlocked,
    required this.onPeople,
    required this.onLogOut,
  });

  final String username;
  final String contact;
  final Widget avatar;
  final bool admin;
  final VoidCallback onProfile;
  final VoidCallback onNewGroup;
  final VoidCallback onJoin;
  final VoidCallback onArchivedChats;
  final VoidCallback onArchivedGroups;
  final VoidCallback onBlocked;
  final VoidCallback onPeople;
  final VoidCallback onLogOut;

  @override
  State<ChatSettingsPage> createState() => _ChatSettingsPageState();
}

class _ChatSettingsPageState extends State<ChatSettingsPage> {
  bool _requests = false;

  @override
  void initState() {
    super.initState();
    ChatPrefs.revision.addListener(_refresh);
    unawaited(ChatPrefs.ensure());
    unawaited(_loadRequests());
  }

  Future<void> _loadRequests() async {
    try {
      final me = await ChatApi().me();
      if (!mounted) return;
      setState(() => _requests = me.messageRequests);
    } catch (_) {}
  }

  Future<void> _setRequests(bool on) async {
    setState(() => _requests = on);
    try {
      final me = await ChatApi().me();
      await ChatApi().setPrivacy(
        online: me.onlinePrivacy,
        lastSeen: me.seenPrivacy,
        photo: me.photoPrivacy,
        receipts: me.receipts,
        requests: on,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _requests = !on);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(chatErrorText(error))),
      );
    }
  }

  @override
  void dispose() {
    ChatPrefs.revision.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _setMessagePopup(bool on) async {
    await ChatPrefs.setMessagePopup(on);
    if (on) return;
    try {
      await const MethodChannel('socialsave/chat_notify').invokeMethod<void>('hidePop');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = ChatUiTokens.dark(context);
    final name = widget.username.replaceFirst(RegExp(r'^@'), '').trim();
    final shown = name.isEmpty ? 'Your profile' : '@$name';
    final quiet = dark ? ChatUiTokens.timeDark : scheme.onSurfaceVariant;
    final android = Theme.of(context).platform == TargetPlatform.android;
    return ListView(
      padding: pagePadding(context, top: 8, bottom: 28, maxWidth: 520),
      children: [
        const SizedBox(height: 12),
        Semantics(
          button: true,
          label: 'Edit profile for $shown',
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: widget.onProfile,
            child: widget.avatar,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          shown,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.4,
          ),
        ),
        if (widget.contact.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            widget.contact.trim(),
            textAlign: TextAlign.center,
            style: TextStyle(color: quiet, height: 1.3),
          ),
        ],
        TextButton(
          onPressed: widget.onProfile,
          style: TextButton.styleFrom(
            foregroundColor: ChatUiTokens.brand,
            minimumSize: const Size(48, 44),
          ),
          child: const Text('Edit profile'),
        ),
        const _Heading('Chats'),
        _Group(
          children: [
            _LinkRow(
              icon: Icons.group_add_outlined,
              title: 'New group',
              onTap: widget.onNewGroup,
            ),
            _LinkRow(
              icon: Icons.vpn_key_outlined,
              title: 'Join with a code',
              onTap: widget.onJoin,
            ),
            _LinkRow(
              icon: Icons.archive_outlined,
              title: 'Archived chats',
              onTap: widget.onArchivedChats,
            ),
            _LinkRow(
              icon: Icons.inventory_2_outlined,
              title: 'Archived groups',
              onTap: widget.onArchivedGroups,
            ),
            _LinkRow(
              icon: Icons.block_rounded,
              title: 'Blocked',
              onTap: widget.onBlocked,
            ),
          ],
        ),
        const _Heading('Messages'),
        _Group(
          children: [
            _SwitchRow(
              icon: Icons.keyboard_return_rounded,
              title: 'Enter key sends',
              subtitle:
                  'Enter sends. Shift+Enter starts a new line on a computer. Off uses Enter for a new line.',
              value: ChatPrefs.keyboardSends,
              onChanged: (on) => unawaited(ChatPrefs.setKeyboardSends(on)),
            ),
            _SwitchRow(
              icon: Icons.volume_up_outlined,
              title: 'Message sound',
              subtitle:
                  'A tone when a message arrives. A muted chat stays quiet, and the notice still shows.',
              value: ChatPrefs.messageSound,
              onChanged: (on) => unawaited(ChatPrefs.setMessageSound(on)),
            ),
            if (android)
              _SwitchRow(
                icon: Icons.chat_bubble_outline_rounded,
                title: 'Green message card',
                subtitle:
                    'The green card over other apps. Off keeps the normal notification.',
                value: ChatPrefs.messagePopup,
                onChanged: (on) => unawaited(_setMessagePopup(on)),
              ),
            _SwitchRow(
              icon: Icons.texture_outlined,
              title: 'Pattern background',
              subtitle: 'A faint pattern behind messages. Off keeps it plain.',
              value: ChatPrefs.pattern,
              onChanged: (on) => unawaited(ChatPrefs.setPattern(on)),
            ),
            _SwitchRow(
              icon: Icons.data_saver_on_outlined,
              title: 'Data saver',
              subtitle:
                  'Photos wait until you tap them, and new messages are checked less often.',
              value: ChatPrefs.dataSaver,
              onChanged: (on) => unawaited(ChatPrefs.setDataSaver(on)),
            ),
            _SwitchRow(
              icon: Icons.mark_email_unread_outlined,
              title: 'Message requests',
              subtitle:
                  'Off puts a new person straight in your chats. On holds their first messages in Requests until you accept.',
              value: _requests,
              onChanged: (on) => unawaited(_setRequests(on)),
            ),
          ],
        ),
        const _Heading('Privacy'),
        _Group(
          children: [
            _LinkRow(
              icon: Icons.lock_outline_rounded,
              title: 'Who can see you',
              onTap: () => unawaited(showChatPrivacy(context)),
            ),
            _LinkRow(
              icon: Icons.bedtime_outlined,
              title: 'Quiet hours',
              onTap: () => unawaited(showQuietHours(context)),
            ),
            _LinkRow(
              icon: Icons.star_outline_rounded,
              title: 'Starred messages',
              onTap: () => unawaited(showStarredMessages(context)),
            ),
            _LinkRow(
              icon: Icons.folder_outlined,
              title: 'Folders',
              onTap: () => unawaited(showChatFolders(context)),
            ),
            _LinkRow(
              icon: Icons.devices_rounded,
              title: 'Devices',
              onTap: () => unawaited(showChatDevices(context)),
            ),
            _LinkRow(
              icon: Icons.vpn_key_outlined,
              title: 'Recovery code',
              onTap: () => unawaited(showRotateRecovery(context)),
            ),
          ],
        ),
        const _Heading('Notifications'),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: Text(
            'Hold a chat, or tap Mute on its notification. Only that conversation goes quiet.',
            style: TextStyle(color: quiet, height: 1.45),
          ),
        ),
        const _Heading('Account'),
        _Group(
          children: [
            _LinkRow(
              icon: Icons.logout_rounded,
              title: 'Log out',
              destructive: true,
              onTap: widget.onLogOut,
            ),
          ],
        ),
        if (widget.admin) ...[
          const _Heading('People'),
          _Group(
            children: [
              _LinkRow(
                icon: Icons.people_outline_rounded,
                title: 'People and devices',
                onTap: widget.onPeople,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final dark = ChatUiTokens.dark(context);
    final line = dark ? const Color(0xFF1F2C34) : const Color(0xFFE4E7EA);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF111B21) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: line),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              children[i],
              if (i != children.length - 1)
                Divider(height: 0.6, thickness: 0.6, indent: 52, color: line),
            ],
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.1,
        ),
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = destructive ? scheme.error : scheme.onSurface;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              if (!destructive)
                Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        child: Row(
          children: [
            Icon(icon, size: 22, color: scheme.onSurface),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: Colors.white,
              activeTrackColor: ChatUiTokens.brand,
            ),
          ],
        ),
      ),
    );
  }
}
