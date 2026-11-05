import 'package:flutter/material.dart';
import 'package:social_save/features/chat/chat_ui.dart';
import 'package:social_save/shared/widgets/page_layout.dart';

/// Account and chat controls. One quiet page, reached from the Settings tab.
class ChatSettingsPage extends StatelessWidget {
  const ChatSettingsPage({
    super.key,
    required this.username,
    required this.contact,
    required this.avatar,
    required this.admin,
    required this.onProfile,
    required this.onNewGroup,
    required this.onJoin,
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
  final VoidCallback onPeople;
  final VoidCallback onLogOut;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = ChatUiTokens.dark(context);
    final name = username.replaceFirst(RegExp(r'^@'), '').trim();
    final shown = name.isEmpty ? 'Your profile' : '@$name';
    return ListView(
      padding: pagePadding(context, top: 8, bottom: 28, maxWidth: 520),
      children: [
        const SizedBox(height: 8),
        _Panel(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 22, 16, 10),
            child: Column(
              children: [
                Semantics(
                  button: true,
                  label: 'Edit profile for $shown',
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onProfile,
                    child: avatar,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  shown,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
                if (contact.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    contact.trim(),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      height: 1.3,
                    ),
                  ),
                ],
                TextButton(
                  onPressed: onProfile,
                  style: TextButton.styleFrom(
                    foregroundColor: ChatUiTokens.brand,
                    minimumSize: const Size(48, 48),
                  ),
                  child: const Text('Edit profile'),
                ),
              ],
            ),
          ),
        ),
        const _Heading('Chats'),
        _SettingRow(
          icon: Icons.group_add_outlined,
          title: 'New group',
          onTap: onNewGroup,
        ),
        _SettingRow(
          icon: Icons.vpn_key_outlined,
          title: 'Join with a code',
          onTap: onJoin,
        ),
        const _Heading('Notifications'),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: Text(
            'Hold a chat, or tap Mute on its notification. Only that conversation goes quiet.',
            style: TextStyle(
              color: dark ? ChatUiTokens.timeDark : scheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
        ),
        const _Heading('Account'),
        _SettingRow(
          icon: Icons.logout_rounded,
          title: 'Log out',
          destructive: true,
          onTap: onLogOut,
        ),
        if (admin) ...[
          const _Heading('People'),
          _SettingRow(
            icon: Icons.people_outline_rounded,
            title: 'Registered people',
            onTap: onPeople,
          ),
        ],
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = ChatUiTokens.dark(context);
    return Material(
      color: dark ? const Color(0xFF111B21) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: dark ? const Color(0xFF1F2C34) : const Color(0xFFE4E7EA),
        ),
      ),
      child: child,
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
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
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
    final dark = ChatUiTokens.dark(context);
    final color = destructive ? scheme.error : scheme.onSurface;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(
        color: dark ? const Color(0xFF1F2C34) : const Color(0xFFE4E7EA),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: dark ? const Color(0xFF111B21) : Colors.white,
        shape: shape,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
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
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
