import 'package:flutter/material.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/features/chat/chat_thread_screen.dart';
import 'package:social_save/features/chat/chat_ui.dart';
import 'package:social_save/shared/widgets/page_layout.dart';

enum _MonitorTab { people, devices }

/// People who registered, and devices that have opened the app.
/// The server returns this only for the admin account.
class ChatAdminScreen extends StatefulWidget {
  const ChatAdminScreen({super.key});

  @override
  State<ChatAdminScreen> createState() => _ChatAdminScreenState();
}

class _ChatAdminScreenState extends State<ChatAdminScreen> {
  final ChatApi _api = ChatApi();
  final TextEditingController _query = TextEditingController();
  List<ChatDirectoryEntry> _people = const [];
  List<ChatDeviceEntry> _devices = const [];
  String? _error;
  bool _loading = true;
  _MonitorTab _tab = _MonitorTab.devices;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final first = _people.isEmpty && _devices.isEmpty;
    if (mounted && (_error != null || !first)) {
      setState(() {
        _error = null;
        _loading = first;
      });
    }
    try {
      final snapshot = await _api.directory();
      if (!mounted) return;
      setState(() {
        _people = snapshot.people;
        _devices = snapshot.devices;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = chatErrorText(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = ChatUiTokens.dark(context);
    final query = _query.text.trim().toLowerCase();
    final people = [
      for (final person in _people)
        if (query.isEmpty ||
            person.username.toLowerCase().contains(query) ||
            person.phone.contains(query) ||
            person.email.toLowerCase().contains(query))
          person,
    ];
    final devices = [
      for (final device in _devices)
        if (query.isEmpty || _deviceMatches(device, query)) device,
    ];
    final today = _devices.where((device) => _openedToday(device.seen)).length;
    final named = _devices.where((device) => device.username.isNotEmpty).length;
    final passwords = _people.where((person) => person.hasPassword).length;
    final shown = _tab == _MonitorTab.people ? people.length : devices.length;
    return Scaffold(
      backgroundColor: dark ? ChatUiTokens.canvasDark : scheme.surface,
      appBar: AppBar(
        title: const Text('Monitor'),
        backgroundColor: dark ? ChatUiTokens.canvasDark : scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: pagePadding(context, top: 4, bottom: 28, maxWidth: 640),
          children: [
            Text(
              'People who registered, and each phone or computer that has opened Social Save.',
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            if (_api.lastStorage.isNotEmpty) _StorageChip(storage: _api.lastStorage),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: TextStyle(color: scheme.error, height: 1.4)),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('Try again')),
            ],
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error == null) ...[
              const SizedBox(height: 16),
              _StatRow(
                people: _people.length,
                devices: _devices.length,
                today: today,
                named: named,
                passwords: passwords,
              ),
              const SizedBox(height: 16),
              SegmentedButton<_MonitorTab>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: _MonitorTab.devices,
                    label: Text('Devices ${_devices.length}'),
                  ),
                  ButtonSegment(
                    value: _MonitorTab.people,
                    label: Text('People ${_people.length}'),
                  ),
                ],
                selected: {_tab},
                onSelectionChanged: (next) {
                  setState(() => _tab = next.first);
                },
              ),
              const SizedBox(height: 12),
              ChatSearchField(
                controller: _query,
                hintText: _tab == _MonitorTab.devices
                    ? 'Search devices'
                    : 'Search people',
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {},
              ),
              const SizedBox(height: 8),
              if (shown == 0)
                Padding(
                  padding: const EdgeInsets.only(top: 28),
                  child: Text(
                    _emptyText(query),
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                )
              else if (_tab == _MonitorTab.devices)
                for (final device in devices) _DeviceRow(device: device)
              else
                for (final person in people) _PersonRow(person: person),
            ],
          ],
        ),
      ),
    );
  }

  String _emptyText(String query) {
    if (query.isNotEmpty) return 'Nothing matches that search.';
    if (_tab == _MonitorTab.devices) {
      if (_api.lastStorage != 's3' && _api.lastStorage.isNotEmpty) {
        return 'No devices yet. This server may have restarted and lost the list. A device shows up again after it opens the app.';
      }
      return 'No devices yet. A phone or computer shows up here after it opens this version of Social Save.';
    }
    if (_api.lastStorage == 's3') return 'No one has registered yet.';
    return 'The server has no accounts. It may have restarted and lost them. Ask people to register again.';
  }
}

bool _deviceMatches(ChatDeviceEntry device, String query) {
  final label = _deviceLabel(device.platform).toLowerCase();
  return label.contains(query) ||
      device.version.contains(query) ||
      device.username.toLowerCase().contains(query) ||
      device.id.contains(query);
}

bool _openedToday(DateTime? at) {
  if (at == null) return false;
  final now = DateTime.now();
  return now.difference(at.toLocal()).inHours < 24;
}

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.people,
    required this.devices,
    required this.today,
    required this.named,
    required this.passwords,
  });

  final int people;
  final int devices;
  final int today;
  final int named;
  final int passwords;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _Stat(value: '$devices', label: 'Devices'),
        _Stat(value: '$today', label: 'Opened today'),
        _Stat(value: '$named', label: 'Signed in'),
        _Stat(value: '$people', label: 'People'),
        _Stat(value: '$passwords', label: 'Passwords'),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final dark = ChatUiTokens.dark(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 104,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF111B21) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: dark ? const Color(0xFF1F2C34) : const Color(0xFFE4E7EA),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _StorageChip extends StatelessWidget {
  const _StorageChip({required this.storage});

  final String storage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ok = storage == 's3';
    final warn = !ok;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: warn
              ? scheme.errorContainer
              : ChatUiTokens.brand.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          _storageText(storage),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: warn ? scheme.onErrorContainer : ChatUiTokens.brand,
          ),
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device});

  final ChatDeviceEntry device;

  @override
  Widget build(BuildContext context) {
    final who = device.username.isEmpty ? 'No chat account' : '@${device.username}';
    final version = device.version.isEmpty ? 'Unknown version' : device.version;
    return _MonitorCard(
      icon: _deviceIcon(device.platform),
      title: _deviceLabel(device.platform),
      subtitle: '$version · $who',
      detail: _seen(context, device.seen),
      foot: device.first == null ? '' : 'First opened ${_when(device.first!)}',
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({required this.person});

  final ChatDirectoryEntry person;

  @override
  Widget build(BuildContext context) {
    final joined = person.created == null ? '' : 'Joined ${_when(person.created!)}';
    final password = person.hasPassword ? 'Password set' : 'No password yet';
    final foot = [
      if (joined.isNotEmpty) joined,
      password,
    ].join(' · ');
    return _MonitorCard(
      leading: ChatFace(name: person.username, size: 40),
      title: '@${person.username}',
      subtitle: person.contact.isEmpty ? 'No phone or email' : person.contact,
      detail: _seen(context, person.lastSeen),
      foot: foot,
    );
  }
}

class _MonitorCard extends StatelessWidget {
  const _MonitorCard({
    this.icon,
    this.leading,
    required this.title,
    required this.subtitle,
    required this.detail,
    required this.foot,
  });

  final IconData? icon;
  final Widget? leading;
  final String title;
  final String subtitle;
  final String detail;
  final String foot;

  @override
  Widget build(BuildContext context) {
    final dark = ChatUiTokens.dark(context);
    final scheme = Theme.of(context).colorScheme;
    final line = dark ? const Color(0xFF1F2C34) : const Color(0xFFE4E7EA);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF111B21) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: line),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              leading ??
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: ChatUiTokens.brand.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: ChatUiTokens.brand, size: 22),
                  ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    if (foot.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        foot,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                detail,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _deviceLabel(String platform) {
  switch (platform) {
    case 'android':
      return 'Android phone';
    case 'windows':
      return 'Windows computer';
    case 'ios':
      return 'iPhone';
    case 'macos':
      return 'Mac';
    case 'linux':
      return 'Linux computer';
    case 'web':
      return 'Browser';
    default:
      return 'Device';
  }
}

IconData _deviceIcon(String platform) {
  switch (platform) {
    case 'android':
    case 'ios':
      return Icons.smartphone_rounded;
    case 'windows':
    case 'macos':
    case 'linux':
      return Icons.computer_rounded;
    case 'web':
      return Icons.language_rounded;
    default:
      return Icons.devices_rounded;
  }
}

String _seen(BuildContext context, DateTime? at) {
  if (at == null) return 'Not seen yet';
  final clock = TimeOfDay.fromDateTime(at.toLocal()).format(context);
  final label = chatPresenceLabel(at, false, DateTime.now(), clock);
  if (label.isEmpty) return 'Not seen yet';
  return label[0].toUpperCase() + label.substring(1);
}

String _storageText(String storage) {
  switch (storage) {
    case 's3':
      return 'Saved online';
    case 's3-error':
      return 'Could not read saved accounts';
    default:
      return 'Temporary storage';
  }
}

String _when(DateTime at) {
  final local = at.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}
