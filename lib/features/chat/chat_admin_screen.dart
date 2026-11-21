import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:social_save/features/chat/chat_api.dart';
import 'package:social_save/features/chat/chat_format.dart';
import 'package:social_save/features/chat/chat_monitor.dart';
import 'package:social_save/features/chat/chat_thread_screen.dart';
import 'package:social_save/features/chat/chat_ui.dart';
import 'package:social_save/shared/widgets/page_layout.dart';
import 'package:social_save/shared/widgets/app_snack.dart';

/// People, devices, groups, and reports.
/// The server returns this only for the admin account.
/// [preview] skips the network so a test can open the page with known rows.
class ChatAdminScreen extends StatefulWidget {
  const ChatAdminScreen({super.key, this.preview});

  final ChatAdminSnapshot? preview;

  @override
  State<ChatAdminScreen> createState() => _ChatAdminScreenState();
}

class _ChatAdminScreenState extends State<ChatAdminScreen> {
  final ChatApi _api = ChatApi();
  final TextEditingController _query = TextEditingController();
  List<ChatDirectoryEntry> _people = const [];
  List<ChatDeviceEntry> _devices = const [];
  List<ChatAdminGroup> _groups = const [];
  List<ChatAdminReport> _reports = const [];
  String _storage = '';
  int _limit = 2000;
  String? _error;
  bool _loading = true;
  String? _opening;
  String? _busy;
  MonitorTab _tab = MonitorTab.devices;
  MonitorDeviceSort _deviceSort = MonitorDeviceSort.lastOpened;
  MonitorPeopleSort _peopleSort = MonitorPeopleSort.joined;
  MonitorGroupSort _groupSort = MonitorGroupSort.newest;
  MonitorReportSort _reportSort = MonitorReportSort.newest;
  MonitorFreshness _freshness = MonitorFreshness.any;
  MonitorPassword _password = MonitorPassword.any;
  bool _signedInOnly = false;
  bool _noContact = false;
  bool _noRecovery = false;
  String _platform = '';
  String _version = '';
  String? _pickKind;
  String? _pickId;

  @override
  void initState() {
    super.initState();
    final preview = widget.preview;
    if (preview != null) {
      _apply(preview);
      _loading = false;
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _apply(ChatAdminSnapshot snapshot) {
    _people = snapshot.people;
    _devices = snapshot.devices;
    _groups = snapshot.groups;
    _reports = snapshot.reports;
    _storage = snapshot.storage;
    _limit = snapshot.deviceLimit > 0 ? snapshot.deviceLimit : 2000;
  }

  Future<void> _load() async {
    final preview = widget.preview;
    if (preview != null) {
      if (!mounted) return;
      setState(() {
        _apply(preview);
        _loading = false;
        _error = null;
      });
      return;
    }
    final first = _people.isEmpty &&
        _devices.isEmpty &&
        _groups.isEmpty &&
        _reports.isEmpty;
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
        _apply(snapshot);
        _storage = _api.lastStorage;
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

  bool get _wide => MediaQuery.sizeOf(context).width >= 840;

  bool get _deviceFiltersClear =>
      _platform.isEmpty &&
      _version.isEmpty &&
      _freshness == MonitorFreshness.any &&
      !_signedInOnly;

  bool get _peopleFiltersClear =>
      _password == MonitorPassword.any && !_noContact && !_noRecovery;

  void _clearDeviceFilters() {
    _platform = '';
    _version = '';
    _freshness = MonitorFreshness.any;
    _signedInOnly = false;
  }

  void _clearPeopleFilters() {
    _password = MonitorPassword.any;
    _noContact = false;
    _noRecovery = false;
  }

  void _select(String kind, String id, {MonitorTab? tab}) {
    setState(() {
      _pickKind = kind;
      _pickId = id;
      if (tab != null) _tab = tab;
    });
  }

  void _clearPick() {
    setState(() {
      _pickKind = null;
      _pickId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = ChatUiTokens.dark(context);
    final wide = _wide;
    final detail = _pickKind == null ? null : _detail(showTitle: wide);
    final showing = !wide && detail != null;
    return Scaffold(
      backgroundColor: dark ? ChatUiTokens.canvasDark : scheme.surface,
      appBar: AppBar(
        leading: showing
            ? BackButton(onPressed: _clearPick)
            : null,
        title: Text(showing ? _detailTitle() : 'Monitor'),
        backgroundColor: dark ? ChatUiTokens.canvasDark : scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: showing
          ? detail
          : wide
          ? Row(
              children: [
                SizedBox(width: 440, child: _list(wide: true)),
                VerticalDivider(
                  width: 1,
                  color: dark ? const Color(0xFF1F2C34) : const Color(0xFFE4E7EA),
                ),
                Expanded(child: detail ?? _placeholder(scheme)),
              ],
            )
          : _list(wide: false),
    );
  }

  Widget _placeholder(ColorScheme scheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Choose a device, person, group, or report.',
          textAlign: TextAlign.center,
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
        ),
      ),
    );
  }

  Widget _list({required bool wide}) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final query = _query.text.trim();
    final searching = query.isNotEmpty;
    final versions = monitorVersions(_devices);
    final devices = monitorSortDevices(
      monitorFilterDevices(
        devices: _devices,
        query: query,
        platform: _platform,
        versionKey: _version,
        versions: versions,
        freshness: _freshness,
        signedInOnly: _signedInOnly,
        now: now,
      ),
      _deviceSort,
    );
    final people = monitorSortPeople(
      monitorFilterPeople(
        people: _people,
        query: query,
        password: _password,
        noContact: _noContact,
        noRecovery: _noRecovery,
      ),
      _peopleSort,
    );
    final groups = monitorSortGroups(
      monitorFilterGroups(_groups, query),
      _groupSort,
    );
    final reports = monitorSortReports(
      monitorFilterReports(_reports, query),
      _reportSort,
    );
    final shares = monitorShares(_people);
    final shown = searching
        ? people.length + devices.length + groups.length + reports.length
        : switch (_tab) {
            MonitorTab.devices => devices.length,
            MonitorTab.people => people.length,
            MonitorTab.groups => groups.length,
            MonitorTab.reports => reports.length,
          };
    final total = switch (_tab) {
      MonitorTab.devices => _devices.length,
      MonitorTab.people => _people.length,
      MonitorTab.groups => _groups.length,
      MonitorTab.reports => _reports.length,
    };
    final countLine = monitorCountLine(
      shown: shown,
      total: total,
      searching: searching,
    );
    final cap = monitorCapNote(_devices.length, _limit);
    final today = monitorToday(
      people: _people,
      devices: _devices,
      reports: _reports,
      now: now,
    );
    final signedIn = _devices.where((device) => device.signedIn).length;
    final passwords = _people.where((person) => person.hasPassword).length;
    final opened = _devices.where((device) => monitorOpenedToday(device.seen, now)).length;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const Key('monitor-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: wide
            ? const EdgeInsets.fromLTRB(16, 4, 12, 28)
            : pagePadding(context, top: 4, bottom: 28, maxWidth: 640),
        children: [
          Text(
            'Every phone or computer that has opened SocialSave, including ones that only save downloads.',
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 8),
          Text(today.line, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          if (cap.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(cap, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          ],
          if (_storage.isNotEmpty) ...[
            const SizedBox(height: 12),
            _StorageChip(storage: _storage, onTap: () => unawaited(_explainStorage())),
          ],
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
              devices: _devices.length,
              opened: opened,
              signedIn: signedIn,
              people: _people.length,
              passwords: passwords,
              devicesOn: _tab == MonitorTab.devices && _deviceFiltersClear,
              openedOn: _tab == MonitorTab.devices &&
                  _freshness == MonitorFreshness.today &&
                  _platform.isEmpty &&
                  _version.isEmpty &&
                  !_signedInOnly,
              signedOn: _tab == MonitorTab.devices &&
                  _signedInOnly &&
                  _freshness == MonitorFreshness.any &&
                  _platform.isEmpty &&
                  _version.isEmpty,
              peopleOn: _tab == MonitorTab.people && _peopleFiltersClear,
              passwordsOn: _tab == MonitorTab.people &&
                  _password == MonitorPassword.set &&
                  !_noContact &&
                  !_noRecovery,
              onDevices: _tapDevices,
              onOpened: _tapOpened,
              onSignedIn: _tapSignedIn,
              onPeople: _tapPeople,
              onPasswords: _tapPasswords,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _tabChip(MonitorTab.devices, 'Devices', _devices.length),
                _tabChip(MonitorTab.people, 'People', _people.length),
                _tabChip(MonitorTab.groups, 'Groups', _groups.length),
                _tabChip(MonitorTab.reports, 'Reports', _reports.length),
              ],
            ),
            const SizedBox(height: 8),
            _sortButton(),
            const SizedBox(height: 4),
            _filters(now, versions),
            const SizedBox(height: 12),
            ChatSearchField(
              controller: _query,
              hintText: 'Search people, devices, groups, and reports',
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {},
            ),
            if (countLine.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(countLine, style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
            const SizedBox(height: 8),
            Text(
              _hint(wide),
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
            ),
            if (shown == 0)
              Padding(
                padding: const EdgeInsets.only(top: 28),
                child: Text(
                  searching ? 'Nothing matches that search.' : _emptyText(query),
                  style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45),
                ),
              )
            else if (searching) ...[
              if (people.isNotEmpty) ...[
                const _Heading('People'),
                for (final person in people) _personTile(person, shares),
              ],
              if (devices.isNotEmpty) ...[
                const _Heading('Devices'),
                for (final device in devices) _deviceTile(device, now),
              ],
              if (groups.isNotEmpty) ...[
                const _Heading('Groups'),
                for (final group in groups) _groupTile(group, wide),
              ],
              if (reports.isNotEmpty) ...[
                const _Heading('Reports'),
                for (final report in reports) _reportTile(report),
              ],
            ] else
              ...switch (_tab) {
                MonitorTab.devices => [
                  for (final device in devices) _deviceTile(device, now),
                ],
                MonitorTab.people => [
                  for (final person in people) _personTile(person, shares),
                ],
                MonitorTab.groups => [
                  for (final group in groups) _groupTile(group, wide),
                ],
                MonitorTab.reports => [
                  for (final report in reports) _reportTile(report),
                ],
              },
          ],
        ],
      ),
    );
  }

  Widget _tabChip(MonitorTab tab, String label, int count) {
    return ChoiceChip(
      label: Text('$label $count'),
      selected: _tab == tab,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      onSelected: (_) => setState(() => _tab = tab),
    );
  }

  Widget _chip(String label, bool selected, ValueChanged<bool> onSelected) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      onSelected: onSelected,
    );
  }

  Widget _filters(DateTime now, MonitorVersions versions) {
    if (_tab == MonitorTab.devices) {
      final quiet7 = _devices.where((device) => monitorQuiet(device.seen, now, 7)).length;
      final quiet30 = _devices.where((device) => monitorQuiet(device.seen, now, 30)).length;
      final today = _devices.where((device) => monitorOpenedToday(device.seen, now)).length;
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _chip('Today $today', _freshness == MonitorFreshness.today, (on) {
            setState(() => _freshness = on ? MonitorFreshness.today : MonitorFreshness.any);
          }),
          _chip('7 days quiet $quiet7', _freshness == MonitorFreshness.quiet7, (on) {
            setState(() => _freshness = on ? MonitorFreshness.quiet7 : MonitorFreshness.any);
          }),
          _chip('30 days quiet $quiet30', _freshness == MonitorFreshness.quiet30, (on) {
            setState(() => _freshness = on ? MonitorFreshness.quiet30 : MonitorFreshness.any);
          }),
          for (final chip in monitorPlatforms(_devices))
            _chip('${chip.label} ${chip.count}', _platform == chip.platform, (on) {
              setState(() => _platform = on ? chip.platform : '');
            }),
          for (final chip in versions.chips)
            _chip('${chip.label} ${chip.count}', _version == chip.keyName, (on) {
              setState(() => _version = on ? chip.keyName : '');
            }),
        ],
      );
    }
    if (_tab == MonitorTab.people) {
      final missing = _people.where((person) => !person.hasPassword).length;
      final bare = _people.where((person) => person.contact.isEmpty).length;
      final recovery = _people.where((person) => !person.hasRecovery).length;
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (missing > 0 || _password == MonitorPassword.missing)
            _chip('No password $missing', _password == MonitorPassword.missing, (on) {
              setState(() {
                _password = on ? MonitorPassword.missing : MonitorPassword.any;
              });
            }),
          if (bare > 0 || _noContact)
            _chip('No phone or email $bare', _noContact, (on) {
              setState(() => _noContact = on);
            }),
          if (recovery > 0 || _noRecovery)
            _chip('No recovery code $recovery', _noRecovery, (on) {
              setState(() => _noRecovery = on);
            }),
        ],
      );
    }
    return const SizedBox.shrink();
  }

  Widget _sortButton() {
    switch (_tab) {
      case MonitorTab.devices:
        return _sortMenu<MonitorDeviceSort>(
          _deviceSort,
          MonitorDeviceSort.values,
          (item) => item.label,
          (item) => setState(() => _deviceSort = item),
        );
      case MonitorTab.people:
        return _sortMenu<MonitorPeopleSort>(
          _peopleSort,
          MonitorPeopleSort.values,
          (item) => item.label,
          (item) => setState(() => _peopleSort = item),
        );
      case MonitorTab.groups:
        return _sortMenu<MonitorGroupSort>(
          _groupSort,
          MonitorGroupSort.values,
          (item) => item.label,
          (item) => setState(() => _groupSort = item),
        );
      case MonitorTab.reports:
        return _sortMenu<MonitorReportSort>(
          _reportSort,
          MonitorReportSort.values,
          (item) => item.label,
          (item) => setState(() => _reportSort = item),
        );
    }
  }

  Widget _sortMenu<T>(
    T value,
    List<T> items,
    String Function(T item) label,
    ValueChanged<T> onSelected,
  ) {
    return Align(
      alignment: Alignment.centerLeft,
      child: PopupMenuButton<T>(
        tooltip: 'Sort',
        initialValue: value,
        onSelected: onSelected,
        itemBuilder: (context) => [
          for (final item in items)
            PopupMenuItem<T>(value: item, child: Text(label(item))),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.sort_rounded, size: 18),
              const SizedBox(width: 6),
              Text(label(value)),
            ],
          ),
        ),
      ),
    );
  }

  String _hint(bool wide) {
    switch (_tab) {
      case MonitorTab.devices:
        return 'Tap a device for its details. Copy keeps the device id.';
      case MonitorTab.people:
        return 'Tap a person for their account. Copy keeps the username.';
      case MonitorTab.groups:
        return wide ? 'Tap a group for its details.' : 'Tap a group to open it.';
      case MonitorTab.reports:
        return 'Tap a report, then open your chat with that person.';
    }
  }

  String _emptyText(String query) {
    if (query.isNotEmpty) return 'Nothing matches that search.';
    switch (_tab) {
      case MonitorTab.devices:
        if (_storage != 's3' && _storage.isNotEmpty) {
          return 'No devices yet. This server may have restarted and lost the list. A device shows up again after it opens the app.';
        }
        return 'No devices yet. A phone or computer shows up here after it opens this version of SocialSave.';
      case MonitorTab.people:
        if (_storage == 's3') return 'No one has registered yet.';
        return 'The server has no accounts. It may have restarted and lost them. Ask people to register again.';
      case MonitorTab.groups:
        return 'No groups yet.';
      case MonitorTab.reports:
        return 'No reports yet.';
    }
  }

  void _tapDevices() {
    final on = _tab == MonitorTab.devices && _deviceFiltersClear;
    setState(() {
      _tab = MonitorTab.devices;
      if (!on) _clearDeviceFilters();
    });
  }

  void _tapOpened() {
    final on = _tab == MonitorTab.devices &&
        _freshness == MonitorFreshness.today &&
        _platform.isEmpty &&
        _version.isEmpty &&
        !_signedInOnly;
    setState(() {
      _tab = MonitorTab.devices;
      _clearDeviceFilters();
      if (!on) _freshness = MonitorFreshness.today;
    });
  }

  void _tapSignedIn() {
    final on = _tab == MonitorTab.devices &&
        _signedInOnly &&
        _freshness == MonitorFreshness.any &&
        _platform.isEmpty &&
        _version.isEmpty;
    setState(() {
      _tab = MonitorTab.devices;
      _clearDeviceFilters();
      if (!on) _signedInOnly = true;
    });
  }

  void _tapPeople() {
    final on = _tab == MonitorTab.people && _peopleFiltersClear;
    setState(() {
      _tab = MonitorTab.people;
      if (!on) _clearPeopleFilters();
    });
  }

  void _tapPasswords() {
    final on = _tab == MonitorTab.people &&
        _password == MonitorPassword.set &&
        !_noContact &&
        !_noRecovery;
    setState(() {
      _tab = MonitorTab.people;
      _clearPeopleFilters();
      if (!on) _password = MonitorPassword.set;
    });
  }

  Widget _deviceTile(ChatDeviceEntry device, DateTime now) {
    final model = device.model.isNotEmpty && device.model != monitorDeviceTitle(device)
        ? device.model
        : '';
    final version = device.version.isEmpty ? 'Unknown version' : device.version;
    final quiet = monitorQuietMark(device.seen, now);
    final saves = device.downloads <= 0
        ? ''
        : device.downloads == 1
        ? '1 save'
        : '${device.downloads} saves';
    final opened = device.first == null ? '' : 'First opened ${_when(device.first!)}';
    return _MonitorCard(
      icon: _deviceIcon(device.platform),
      title: monitorDeviceTitle(device),
      subtitle: [
        if (model.isNotEmpty) model,
        monitorDeviceLabel(device.platform),
        version,
      ].join(' · '),
      detail: _seen(context, device.seen),
      foot: [
        monitorAccountLine(device),
        if (saves.isNotEmpty) saves,
        if (opened.isNotEmpty) opened,
        if (quiet.isNotEmpty) quiet,
      ].join(' · '),
      selected: _pickKind == 'device' && _pickId == device.id,
      onTap: () => _select('device', device.id),
      trailing: IconButton(
        tooltip: 'Copy device id',
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
        onPressed: () => unawaited(_copy(device.id, 'Copied device id')),
        icon: const Icon(Icons.copy_rounded, size: 20),
      ),
    );
  }

  Widget _personTile(
    ChatDirectoryEntry person,
    Map<String, MonitorShare> shares,
  ) {
    final joined = person.created == null ? '' : 'Joined ${_when(person.created!)}';
    final share = shares[person.username];
    return _MonitorCard(
      leading: ChatFace(name: person.username, size: 40),
      title: '@${person.username}',
      subtitle: person.contact.isEmpty ? 'No phone or email' : person.contact,
      detail: _seen(context, person.lastSeen),
      foot: [
        if (joined.isNotEmpty) joined,
        person.hasPassword ? 'Password set' : 'No password yet',
        if (!person.hasRecovery) 'No recovery code',
        if (share != null && share.line.isNotEmpty) share.line,
        if (person.disabled) 'Disabled',
      ].join(' · '),
      selected: _pickKind == 'person' && _pickId == person.username,
      onTap: () => _select('person', person.username),
      trailing: IconButton(
        tooltip: 'Copy username',
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 36, height: 36),
        onPressed: () => unawaited(_copy('@${person.username}', 'Copied @${person.username}')),
        icon: const Icon(Icons.copy_rounded, size: 20),
      ),
    );
  }

  Widget _groupTile(ChatAdminGroup group, bool wide) {
    final members = group.members == 1 ? '1 member' : '${group.members} members';
    final owner = group.owner.isEmpty ? 'No owner' : '@${group.owner}';
    return _MonitorCard(
      icon: Icons.groups_rounded,
      title: group.name.isEmpty ? 'Group' : group.name,
      subtitle: [
        owner,
        members,
        group.announce ? 'Only admins can post' : 'Anyone can post',
      ].join(' · '),
      detail: group.created == null ? '' : _seen(context, group.created),
      foot: group.created == null ? '' : 'Created ${_when(group.created!)}',
      selected: _pickKind == 'group' && _pickId == group.id,
      onTap: () {
        if (wide) {
          _select('group', group.id);
        } else {
          unawaited(_openGroup(group));
        }
      },
    );
  }

  Widget _reportTile(ChatAdminReport report) {
    return _MonitorCard(
      icon: Icons.flag_rounded,
      title: '@${report.from} reported @${report.target}',
      subtitle: report.reason.isEmpty ? 'No reason given' : report.reason,
      detail: _seen(context, report.at),
      foot: report.at == null ? '' : _when(report.at!),
      selected: _pickKind == 'report' && _pickId == report.id,
      onTap: () => _select('report', report.id),
    );
  }

  String _detailTitle() {
    final device = _pickedDevice();
    if (device != null) return monitorDeviceTitle(device);
    final person = _pickedPerson();
    if (person != null) return '@${person.username}';
    final group = _pickedGroup();
    if (group != null) return group.name.isEmpty ? 'Group' : group.name;
    if (_pickedReport() != null) return 'Report';
    return 'Monitor';
  }

  Widget _detail({required bool showTitle}) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final facts = _detailFacts(now);
    final children = <Widget>[
      if (showTitle)
        Row(
          children: [
            Expanded(
              child: Text(
                _detailTitle(),
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: 'Close',
              onPressed: _clearPick,
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      if (facts.isEmpty)
        Text(
          'That row is no longer in the list.',
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
        )
      else
        ...facts,
    ];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        key: const Key('monitor-detail'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: showTitle
            ? const EdgeInsets.fromLTRB(20, 12, 20, 28)
            : pagePadding(context, top: 4, bottom: 28, maxWidth: 640),
        children: children,
      ),
    );
  }

  List<Widget> _detailFacts(DateTime now) {
    final device = _pickedDevice();
    if (device != null) return _deviceFacts(device, now);
    final person = _pickedPerson();
    if (person != null) return _personFacts(person, now);
    final group = _pickedGroup();
    if (group != null) return _groupFacts(group);
    final report = _pickedReport();
    if (report != null) return _reportFacts(report);
    return const [];
  }

  ChatDeviceEntry? _pickedDevice() {
    if (_pickKind != 'device') return null;
    for (final device in _devices) {
      if (device.id == _pickId) return device;
    }
    return null;
  }

  ChatDirectoryEntry? _pickedPerson() {
    if (_pickKind != 'person') return null;
    for (final person in _people) {
      if (person.username == _pickId) return person;
    }
    return null;
  }

  ChatAdminGroup? _pickedGroup() {
    if (_pickKind != 'group') return null;
    for (final group in _groups) {
      if (group.id == _pickId) return group;
    }
    return null;
  }

  ChatAdminReport? _pickedReport() {
    if (_pickKind != 'report') return null;
    for (final report in _reports) {
      if (report.id == _pickId) return report;
    }
    return null;
  }

  ChatDirectoryEntry? _personNamed(String username) {
    final name = username.trim().toLowerCase();
    for (final person in _people) {
      if (person.username.toLowerCase() == name) return person;
    }
    return null;
  }

  List<Widget> _deviceFacts(ChatDeviceEntry device, DateTime now) {
    final quiet = monitorQuietMark(device.seen, now);
    return [
      _fact(monitorAccountLine(device)),
      _fact(monitorDeviceLabel(device.platform)),
      if (device.model.isNotEmpty) _fact(device.model),
      _fact(device.version.isEmpty ? 'Unknown version' : device.version),
      _fact(device.first == null ? 'First open unknown' : 'First opened ${_when(device.first!)}'),
      _fact(device.seen == null ? 'Not opened yet' : 'Last opened ${_when(device.seen!)}'),
      _fact(_saveLine(device)),
      if (quiet.isNotEmpty) _fact(quiet),
      const SizedBox(height: 8),
      SelectableText(device.id),
      _button(
        'Copy device id',
        () => unawaited(_copy(device.id, 'Copied device id')),
      ),
      if (device.username.isNotEmpty)
        _button('View @${device.username}', () {
          final person = _personNamed(device.username);
          if (person == null) {
            AppSnack.info(context, 'No account uses that username.');
            return;
          }
          _select('person', person.username, tab: MonitorTab.people);
        }),
    ];
  }

  List<Widget> _personFacts(ChatDirectoryEntry person, DateTime now) {
    final share = monitorShares(_people)[person.username];
    final installs = [
      for (final device in _devices)
        if (device.username.toLowerCase() == person.username.toLowerCase()) device,
    ];
    final others = person.sessions.where((session) => !session.current).length;
    final self = person.sessions.any((session) => session.current);
    return [
      _fact(person.contact.isEmpty ? 'No phone or email' : person.contact),
      _fact(person.created == null ? 'Join date unknown' : 'Joined ${_when(person.created!)}'),
      _fact(_seen(context, person.lastSeen)),
      _fact(person.hasPassword ? 'Password set' : 'No password yet'),
      _fact(person.hasRecovery ? 'Recovery code set' : 'No recovery code'),
      _fact(person.disabled ? 'Disabled' : 'Active'),
      if (share != null && share.line.isNotEmpty) _fact(share.line),
      _button(
        _opening == person.username ? 'Opening…' : 'Open chat',
        _opening != null || _busy != null
            ? null
            : () => unawaited(_openPerson(person.username)),
      ),
      const _Heading('Devices that opened the app'),
      if (installs.isEmpty)
        _fact('No device has opened the app with this username.')
      else
        for (final device in installs)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(monitorDeviceTitle(device)),
            subtitle: Text(
              '${monitorDeviceShort(device.platform)} · ${device.version.isEmpty ? 'Unknown version' : device.version} · ${device.signedIn ? 'Signed in' : 'Last signed in'}',
            ),
            onTap: () => _select('device', device.id, tab: MonitorTab.devices),
          ),
      const _Heading('Signed-in sessions'),
      _fact('These are sign-ins, separate from devices that only opened the app.'),
      if (person.sessions.isEmpty)
        _fact('No signed-in session.')
      else
        for (final session in person.sessions) _sessionTile(person, session),
      if (others > 0)
        _button(
          self ? 'Sign out other devices' : 'Sign out everywhere',
          _busy != null ? null : () => unawaited(_endAll(person)),
          destructive: true,
        ),
      const SizedBox(height: 8),
      if (_protected(person.username))
        _fact('This account stays open.')
      else
        _button(
          person.disabled ? 'Allow again' : 'Disable',
          _busy != null ? null : () => unawaited(_toggleDisabled(person)),
          destructive: !person.disabled,
        ),
    ];
  }

  Widget _sessionTile(ChatDirectoryEntry person, ChatAdminSession session) {
    final name = session.name.isNotEmpty
        ? session.name
        : monitorDeviceLabel(session.platform);
    final when = session.seen == null ? '' : _seen(context, session.seen);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(session.current ? '$name · This device' : name),
      subtitle: Text(
        [
          if (session.platform.isNotEmpty) monitorDeviceShort(session.platform),
          if (when.isNotEmpty) when,
        ].join(' · '),
      ),
      trailing: session.current
          ? null
          : TextButton(
              onPressed: _busy != null ? null : () => unawaited(_endOne(person, session)),
              child: const Text('Sign out'),
            ),
    );
  }

  List<Widget> _groupFacts(ChatAdminGroup group) {
    final members = group.members == 1 ? '1 member' : '${group.members} members';
    return [
      _fact(group.owner.isEmpty ? 'No owner' : 'Owner @${group.owner}'),
      _fact(members),
      _fact(group.announce ? 'Only admins can post' : 'Anyone can post'),
      _fact(group.created == null ? 'Created date unknown' : 'Created ${_when(group.created!)}'),
      _button('Open group', () => unawaited(_openGroup(group))),
    ];
  }

  List<Widget> _reportFacts(ChatAdminReport report) {
    return [
      _fact('@${report.from} reported @${report.target}'),
      _fact(report.reason.isEmpty ? 'No reason given' : report.reason),
      if (report.at != null) _fact(_when(report.at!)),
      _fact('Open chat starts your conversation with them.'),
      _button(
        'Open @${report.target}',
        _opening != null || _busy != null
            ? null
            : () => unawaited(_openPerson(report.target)),
      ),
      if (report.from != report.target)
        _button(
          'Open @${report.from}',
          _opening != null || _busy != null
              ? null
              : () => unawaited(_openPerson(report.from)),
          filled: false,
        ),
    ];
  }

  Widget _fact(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(text, style: const TextStyle(height: 1.4)),
    );
  }

  Widget _button(
    String label,
    VoidCallback? onPressed, {
    bool destructive = false,
    bool filled = true,
  }) {
    final child = Text(label);
    final button = destructive
        ? OutlinedButton(onPressed: onPressed, child: child)
        : filled
        ? FilledButton(onPressed: onPressed, child: child)
        : OutlinedButton(onPressed: onPressed, child: child);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Align(alignment: Alignment.centerLeft, child: button),
    );
  }

  String _saveLine(ChatDeviceEntry device) {
    if (device.downloads <= 0) return 'No saves yet';
    final count = device.downloads == 1 ? '1 save' : '${device.downloads} saves';
    if (device.lastDownload == null) return count;
    return '$count · Last save ${_when(device.lastDownload!)}';
  }

  Future<void> _explainStorage() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(monitorStorageLabel(_storage)),
        content: Text(monitorStorageDetail(_storage)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirm(
    String title,
    String body,
    String action, {
    bool destructive = false,
  }) async {
    final scheme = Theme.of(context).colorScheme;
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              action,
              style: destructive ? TextStyle(color: scheme.error) : null,
            ),
          ),
        ],
      ),
    );
    return answer == true;
  }

  Future<void> _run(String key, Future<void> Function() action) async {
    setState(() => _busy = key);
    try {
      await action();
      if (!mounted) return;
      await _load();
    } catch (error) {
      if (!mounted) return;
      AppSnack.error(context, chatErrorText(error));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  bool _protected(String username) => username.toLowerCase() == 'daniel256';

  Future<void> _toggleDisabled(ChatDirectoryEntry person) async {
    if (_protected(person.username)) return;
    final disabling = !person.disabled;
    final ok = await _confirm(
      disabling ? 'Disable @${person.username}?' : 'Allow @${person.username}?',
      disabling
          ? 'They cannot send a message, start a call, or post a status. Their chats stay.'
          : 'They can send, start a call, and post a status again.',
      disabling ? 'Disable' : 'Allow',
      destructive: disabling,
    );
    if (!ok || !mounted) return;
    await _run(
      'disable:${person.username}',
      () => _api.setAccountDisabled(person.username, disabled: disabling),
    );
  }

  Future<void> _endOne(ChatDirectoryEntry person, ChatAdminSession session) async {
    final label = session.name.isNotEmpty
        ? session.name
        : monitorDeviceLabel(session.platform);
    final ok = await _confirm(
      'Sign @${person.username} out?',
      'Sign them out of $label. They need to sign in there again.',
      'Sign out',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _run(
      'end:${person.username}:${session.id}',
      () => _api.endAccountSession(person.username, session.id),
    );
  }

  Future<void> _endAll(ChatDirectoryEntry person) async {
    final self = person.sessions.any((session) => session.current);
    final ok = await _confirm(
      self
          ? 'Sign out of your other devices?'
          : 'Sign @${person.username} out everywhere?',
      self
          ? 'Your other sessions end. This one stays signed in.'
          : 'Every session ends. They need to sign in again.',
      'Sign out',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _run(
      'end-all:${person.username}',
      () => _api.endAccountSessions(person.username),
    );
  }

  Future<void> _openPerson(String username) async {
    final name = username.trim();
    if (name.isEmpty || _opening != null) return;
    setState(() => _opening = name);
    try {
      final opened = await _api.openThread(name);
      if (!mounted) return;
      setState(() => _opening = null);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatThreadScreen(
            threadId: opened.id,
            username: opened.username,
            seenName: opened.name,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _opening = null);
      AppSnack.error(context, chatErrorText(error));
    }
  }

  Future<void> _openGroup(ChatAdminGroup group) async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatThreadScreen(
          threadId: group.id,
          username: group.name.isEmpty ? 'Group' : group.name,
          group: true,
        ),
      ),
    );
  }

  Future<void> _copy(String value, String label) async {
    final text = value.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    AppSnack.info(context, label);
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.devices,
    required this.opened,
    required this.signedIn,
    required this.people,
    required this.passwords,
    required this.devicesOn,
    required this.openedOn,
    required this.signedOn,
    required this.peopleOn,
    required this.passwordsOn,
    required this.onDevices,
    required this.onOpened,
    required this.onSignedIn,
    required this.onPeople,
    required this.onPasswords,
  });

  final int devices;
  final int opened;
  final int signedIn;
  final int people;
  final int passwords;
  final bool devicesOn;
  final bool openedOn;
  final bool signedOn;
  final bool peopleOn;
  final bool passwordsOn;
  final VoidCallback onDevices;
  final VoidCallback onOpened;
  final VoidCallback onSignedIn;
  final VoidCallback onPeople;
  final VoidCallback onPasswords;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _Stat(value: '$devices', label: 'Devices', selected: devicesOn, onTap: onDevices),
        _Stat(value: '$opened', label: 'Opened today', selected: openedOn, onTap: onOpened),
        _Stat(value: '$signedIn', label: 'Signed in', selected: signedOn, onTap: onSignedIn),
        _Stat(value: '$people', label: 'People', selected: peopleOn, onTap: onPeople),
        _Stat(value: '$passwords', label: 'Passwords', selected: passwordsOn, onTap: onPasswords),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.value,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String value;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = ChatUiTokens.dark(context);
    final scheme = Theme.of(context).colorScheme;
    final line = selected
        ? ChatUiTokens.brand
        : dark
        ? const Color(0xFF1F2C34)
        : const Color(0xFFE4E7EA);
    return Material(
      color: dark ? const Color(0xFF111B21) : Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 104,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: line, width: selected ? 1.6 : 1),
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
        ),
      ),
    );
  }
}

class _StorageChip extends StatelessWidget {
  const _StorageChip({required this.storage, required this.onTap});

  final String storage;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ok = storage == 's3';
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: ok
            ? ChatUiTokens.brand.withValues(alpha: 0.14)
            : scheme.errorContainer,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              monitorStorageLabel(storage),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: ok ? ChatUiTokens.brand : scheme.onErrorContainer,
              ),
            ),
          ),
        ),
      ),
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
    this.onTap,
    this.trailing,
    this.selected = false,
  });

  final IconData? icon;
  final Widget? leading;
  final String title;
  final String subtitle;
  final String detail;
  final String foot;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final dark = ChatUiTokens.dark(context);
    final scheme = Theme.of(context).colorScheme;
    final line = selected
        ? ChatUiTokens.brand
        : dark
        ? const Color(0xFF1F2C34)
        : const Color(0xFFE4E7EA);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: dark ? const Color(0xFF111B21) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: line, width: selected ? 1.6 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
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
                      if (detail.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          detail,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ],
                      if (foot.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          foot,
                          maxLines: 3,
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
                if (trailing != null) ...[
                  const SizedBox(width: 4),
                  trailing!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
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

String _when(DateTime at) {
  final local = at.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}
