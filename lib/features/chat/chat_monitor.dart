import 'package:social_save/features/chat/chat_api.dart';

/// Which list Monitor is showing.
enum MonitorTab { devices, people, groups, reports }

enum MonitorDeviceSort {
  lastOpened('Last opened'),
  firstOpened('First opened'),
  saves('Most saves'),
  version('Version'),
  name('Name');

  const MonitorDeviceSort(this.label);
  final String label;
}

enum MonitorPeopleSort {
  joined('Newest'),
  lastSeen('Last seen'),
  noPassword('No password first'),
  name('Name');

  const MonitorPeopleSort(this.label);
  final String label;
}

enum MonitorGroupSort {
  newest('Newest'),
  name('Name'),
  members('Most members');

  const MonitorGroupSort(this.label);
  final String label;
}

enum MonitorReportSort {
  newest('Newest'),
  oldest('Oldest');

  const MonitorReportSort(this.label);
  final String label;
}

enum MonitorFreshness { any, today, quiet7, quiet30 }

enum MonitorPassword { any, set, missing }

/// One version chip. [keyName] is the version, `older`, or `unknown`.
class MonitorVersionChip {
  const MonitorVersionChip({
    required this.keyName,
    required this.label,
    required this.count,
  });

  final String keyName;
  final String label;
  final int count;
}

class MonitorVersions {
  const MonitorVersions({required this.chips, required this.older});

  final List<MonitorVersionChip> chips;
  final Set<String> older;

  bool matches(String version, String keyName) {
    if (keyName.isEmpty) return true;
    final value = version.trim();
    if (keyName == 'unknown') return value.isEmpty;
    if (keyName == 'older') return older.contains(value);
    return value == keyName;
  }
}

class MonitorPlatformChip {
  const MonitorPlatformChip({
    required this.platform,
    required this.label,
    required this.count,
  });

  final String platform;
  final String label;
  final int count;
}

class MonitorShare {
  const MonitorShare({this.phones = const [], this.emails = const []});

  final List<String> phones;
  final List<String> emails;

  bool get shared => phones.isNotEmpty || emails.isNotEmpty;

  String get line {
    final parts = <String>[];
    if (phones.length == 1) {
      parts.add('Same phone as @${phones.first}');
    } else if (phones.length > 1) {
      parts.add('Same phone as ${phones.length} accounts');
    }
    if (emails.length == 1) {
      parts.add('Same email as @${emails.first}');
    } else if (emails.length > 1) {
      parts.add('Same email as ${emails.length} accounts');
    }
    return parts.join(' · ');
  }
}

class MonitorToday {
  const MonitorToday({
    required this.accounts,
    required this.opened,
    required this.saves,
    required this.reports,
  });

  final int accounts;
  final int opened;
  final int saves;
  final int reports;

  String get line {
    String count(int n, String one, String many) => n == 1 ? '1 $one' : '$n $many';
    return 'Today: ${count(accounts, 'new account', 'new accounts')} · ${count(opened, 'device opened', 'devices opened')} · ${count(saves, 'device saved', 'devices saved')} · ${count(reports, 'report waiting', 'reports waiting')}';
  }
}

const monitorPlatformOrder = [
  'android',
  'windows',
  'ios',
  'macos',
  'linux',
  'web',
];

bool monitorOpenedToday(DateTime? at, DateTime now) {
  if (at == null) return false;
  return now.difference(at.toLocal()).inHours < 24;
}

/// True when [at] is missing or at least [days] old.
bool monitorQuiet(DateTime? at, DateTime now, int days) {
  if (at == null) return true;
  return now.difference(at.toLocal()) >= Duration(days: days);
}

String monitorQuietMark(DateTime? seen, DateTime now) {
  if (seen == null) return 'Not opened yet';
  if (monitorQuiet(seen, now, 30)) return 'Quiet 30 days';
  if (monitorQuiet(seen, now, 7)) return 'Quiet 7 days';
  return '';
}

String monitorDeviceLabel(String platform) {
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

String monitorDeviceShort(String platform) {
  switch (platform) {
    case 'android':
      return 'Android';
    case 'windows':
      return 'Windows';
    case 'ios':
      return 'iPhone';
    case 'macos':
      return 'Mac';
    case 'linux':
      return 'Linux';
    case 'web':
      return 'Browser';
    default:
      return 'Other';
  }
}

String monitorDeviceTitle(ChatDeviceEntry device) {
  if (device.name.isNotEmpty) return device.name;
  if (device.model.isNotEmpty) return device.model;
  return monitorDeviceLabel(device.platform);
}

String monitorAccountLine(ChatDeviceEntry device) {
  if (device.username.isEmpty) return 'Opened without an account';
  if (device.signedIn) return '@${device.username}';
  return 'Last signed in as @${device.username}';
}

int monitorCompareVersions(String a, String b) {
  if (a.isEmpty && b.isEmpty) return 0;
  if (a.isEmpty) return -1;
  if (b.isEmpty) return 1;
  final ap = a.split('.');
  final bp = b.split('.');
  final n = ap.length > bp.length ? ap.length : bp.length;
  for (var i = 0; i < n; i++) {
    final av = i < ap.length ? int.tryParse(ap[i]) ?? 0 : 0;
    final bv = i < bp.length ? int.tryParse(bp[i]) ?? 0 : 0;
    if (av != bv) return av.compareTo(bv);
  }
  return a.compareTo(b);
}

MonitorVersions monitorVersions(List<ChatDeviceEntry> devices) {
  final counts = <String, int>{};
  for (final device in devices) {
    final version = device.version.trim();
    counts[version] = (counts[version] ?? 0) + 1;
  }
  final known = counts.keys.where((version) => version.isNotEmpty).toList()
    ..sort((a, b) => monitorCompareVersions(b, a));
  final chips = <MonitorVersionChip>[];
  final older = <String>{};
  if (known.length <= 4) {
    for (final version in known) {
      chips.add(
        MonitorVersionChip(
          keyName: version,
          label: version,
          count: counts[version] ?? 0,
        ),
      );
    }
  } else {
    for (final version in known.take(3)) {
      chips.add(
        MonitorVersionChip(
          keyName: version,
          label: version,
          count: counts[version] ?? 0,
        ),
      );
    }
    var rest = 0;
    for (final version in known.skip(3)) {
      older.add(version);
      rest += counts[version] ?? 0;
    }
    chips.add(MonitorVersionChip(keyName: 'older', label: 'Older', count: rest));
  }
  final unknown = counts[''] ?? 0;
  if (unknown > 0) {
    chips.add(
      MonitorVersionChip(keyName: 'unknown', label: 'Unknown', count: unknown),
    );
  }
  return MonitorVersions(chips: chips, older: older);
}

List<MonitorPlatformChip> monitorPlatforms(List<ChatDeviceEntry> devices) {
  final counts = <String, int>{};
  for (final device in devices) {
    final platform = device.platform.trim();
    if (platform.isEmpty) continue;
    counts[platform] = (counts[platform] ?? 0) + 1;
  }
  final ordered = <String>[
    for (final platform in monitorPlatformOrder)
      if (counts.containsKey(platform)) platform,
    for (final platform in counts.keys)
      if (!monitorPlatformOrder.contains(platform)) platform,
  ];
  return [
    for (final platform in ordered)
      MonitorPlatformChip(
        platform: platform,
        label: monitorDeviceShort(platform),
        count: counts[platform] ?? 0,
      ),
  ];
}

bool monitorPersonMatches(ChatDirectoryEntry person, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return person.username.toLowerCase().contains(q) ||
      person.phone.toLowerCase().contains(q) ||
      person.email.toLowerCase().contains(q);
}

bool monitorDeviceMatches(ChatDeviceEntry device, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  final label = monitorDeviceLabel(device.platform).toLowerCase();
  final short = monitorDeviceShort(device.platform).toLowerCase();
  return label.contains(q) ||
      short.contains(q) ||
      device.name.toLowerCase().contains(q) ||
      device.model.toLowerCase().contains(q) ||
      device.version.toLowerCase().contains(q) ||
      device.username.toLowerCase().contains(q) ||
      device.id.toLowerCase().contains(q);
}

bool monitorGroupMatches(ChatAdminGroup group, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return group.name.toLowerCase().contains(q) ||
      group.owner.toLowerCase().contains(q);
}

bool monitorReportMatches(ChatAdminReport report, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return report.from.toLowerCase().contains(q) ||
      report.target.toLowerCase().contains(q) ||
      report.reason.toLowerCase().contains(q);
}

List<ChatDeviceEntry> monitorFilterDevices({
  required List<ChatDeviceEntry> devices,
  required String query,
  required String platform,
  required String versionKey,
  required MonitorVersions versions,
  required MonitorFreshness freshness,
  required bool signedInOnly,
  required DateTime now,
}) {
  return [
    for (final device in devices)
      if (monitorDeviceMatches(device, query) &&
          (platform.isEmpty || device.platform == platform) &&
          versions.matches(device.version, versionKey) &&
          (!signedInOnly || device.signedIn) &&
          _fresh(device.seen, freshness, now))
        device,
  ];
}

bool _fresh(DateTime? seen, MonitorFreshness freshness, DateTime now) {
  switch (freshness) {
    case MonitorFreshness.any:
      return true;
    case MonitorFreshness.today:
      return monitorOpenedToday(seen, now);
    case MonitorFreshness.quiet7:
      return monitorQuiet(seen, now, 7);
    case MonitorFreshness.quiet30:
      return monitorQuiet(seen, now, 30);
  }
}

List<ChatDeviceEntry> monitorSortDevices(
  List<ChatDeviceEntry> devices,
  MonitorDeviceSort sort,
) {
  final next = [...devices];
  next.sort((a, b) {
    switch (sort) {
      case MonitorDeviceSort.lastOpened:
        return _descDate(a.seen, b.seen);
      case MonitorDeviceSort.firstOpened:
        return _descDate(a.first, b.first);
      case MonitorDeviceSort.saves:
        final saves = b.downloads.compareTo(a.downloads);
        if (saves != 0) return saves;
        return _descDate(a.seen, b.seen);
      case MonitorDeviceSort.version:
        final version = monitorCompareVersions(b.version, a.version);
        if (version != 0) return version;
        return _descDate(a.seen, b.seen);
      case MonitorDeviceSort.name:
        return monitorDeviceTitle(a).toLowerCase().compareTo(
          monitorDeviceTitle(b).toLowerCase(),
        );
    }
  });
  return next;
}

List<ChatDirectoryEntry> monitorFilterPeople({
  required List<ChatDirectoryEntry> people,
  required String query,
  required MonitorPassword password,
  required bool noContact,
  required bool noRecovery,
}) {
  return [
    for (final person in people)
      if (monitorPersonMatches(person, query) &&
          _passwordOk(person, password) &&
          (!noContact || person.contact.isEmpty) &&
          (!noRecovery || !person.hasRecovery))
        person,
  ];
}

bool _passwordOk(ChatDirectoryEntry person, MonitorPassword password) {
  switch (password) {
    case MonitorPassword.any:
      return true;
    case MonitorPassword.set:
      return person.hasPassword;
    case MonitorPassword.missing:
      return !person.hasPassword;
  }
}

List<ChatDirectoryEntry> monitorSortPeople(
  List<ChatDirectoryEntry> people,
  MonitorPeopleSort sort,
) {
  final next = [...people];
  next.sort((a, b) {
    switch (sort) {
      case MonitorPeopleSort.joined:
        final created = _descDate(a.created, b.created);
        if (created != 0) return created;
        return a.username.compareTo(b.username);
      case MonitorPeopleSort.lastSeen:
        return _descDate(a.lastSeen, b.lastSeen);
      case MonitorPeopleSort.noPassword:
        if (a.hasPassword != b.hasPassword) return a.hasPassword ? 1 : -1;
        return _descDate(a.created, b.created);
      case MonitorPeopleSort.name:
        return a.username.toLowerCase().compareTo(b.username.toLowerCase());
    }
  });
  return next;
}

List<ChatAdminGroup> monitorFilterGroups(
  List<ChatAdminGroup> groups,
  String query,
) {
  return [
    for (final group in groups)
      if (monitorGroupMatches(group, query)) group,
  ];
}

List<ChatAdminGroup> monitorSortGroups(
  List<ChatAdminGroup> groups,
  MonitorGroupSort sort,
) {
  final next = [...groups];
  next.sort((a, b) {
    switch (sort) {
      case MonitorGroupSort.newest:
        final created = _descDate(a.created, b.created);
        if (created != 0) return created;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case MonitorGroupSort.name:
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      case MonitorGroupSort.members:
        final members = b.members.compareTo(a.members);
        if (members != 0) return members;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    }
  });
  return next;
}

List<ChatAdminReport> monitorFilterReports(
  List<ChatAdminReport> reports,
  String query,
) {
  return [
    for (final report in reports)
      if (monitorReportMatches(report, query)) report,
  ];
}

List<ChatAdminReport> monitorSortReports(
  List<ChatAdminReport> reports,
  MonitorReportSort sort,
) {
  final next = [...reports];
  next.sort((a, b) {
    final order = sort == MonitorReportSort.oldest
        ? _ascDate(a.at, b.at)
        : _descDate(a.at, b.at);
    if (order != 0) return order;
    return a.id.compareTo(b.id);
  });
  return next;
}

Map<String, MonitorShare> monitorShares(List<ChatDirectoryEntry> people) {
  final byPhone = <String, List<String>>{};
  final byEmail = <String, List<String>>{};
  for (final person in people) {
    final phone = person.phone.replaceAll(RegExp(r'\D'), '');
    if (phone.length >= 8) {
      byPhone.putIfAbsent(phone, () => []).add(person.username);
    }
    final email = person.email.trim().toLowerCase();
    if (email.contains('@')) {
      byEmail.putIfAbsent(email, () => []).add(person.username);
    }
  }
  final phones = <String, List<String>>{};
  final emails = <String, List<String>>{};
  void fill(Map<String, List<String>> groups, Map<String, List<String>> out) {
    for (final names in groups.values) {
      if (names.length < 2) continue;
      for (final name in names) {
        out.putIfAbsent(name, () => []).addAll(
          names.where((other) => other != name),
        );
      }
    }
  }

  fill(byPhone, phones);
  fill(byEmail, emails);
  final result = <String, MonitorShare>{};
  for (final name in {...phones.keys, ...emails.keys}) {
    result[name] = MonitorShare(
      phones: phones[name] ?? const [],
      emails: emails[name] ?? const [],
    );
  }
  return result;
}

MonitorToday monitorToday({
  required List<ChatDirectoryEntry> people,
  required List<ChatDeviceEntry> devices,
  required List<ChatAdminReport> reports,
  required DateTime now,
}) {
  return MonitorToday(
    accounts: people.where((person) => monitorOpenedToday(person.created, now)).length,
    opened: devices.where((device) => monitorOpenedToday(device.seen, now)).length,
    saves: devices
        .where((device) => monitorOpenedToday(device.lastDownload, now))
        .length,
    reports: reports.length,
  );
}

String monitorCapNote(int count, int limit) {
  if (limit <= 0 || count < limit) return '';
  return 'Showing the ${_grouped(limit)} most recently opened.';
}

String monitorCountLine({
  required int shown,
  required int total,
  required bool searching,
}) {
  if (searching) return shown == 1 ? '1 match' : '$shown matches';
  if (shown == total) return '';
  return '$shown of $total';
}

String monitorStorageDetail(String storage) {
  switch (storage) {
    case 's3':
      return 'Accounts and devices are saved online. A restart keeps this list.';
    case 's3-error':
      return 'The saved copy of accounts could not be read. A restart can wipe the list that is only in memory. A device shows up again after it opens the app.';
    default:
      return 'Accounts and the device list are only on this server for now. A restart can wipe them. A device shows up again after it opens the app. Ask people to register again if their accounts disappear.';
  }
}

String monitorStorageLabel(String storage) {
  switch (storage) {
    case 's3':
      return 'Saved online';
    case 's3-error':
      return 'Could not read saved accounts';
    default:
      return 'Temporary storage';
  }
}

int _descDate(DateTime? a, DateTime? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return b.compareTo(a);
}

int _ascDate(DateTime? a, DateTime? b) => _descDate(b, a);

String _grouped(int value) {
  final raw = '$value';
  final out = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    final left = raw.length - i;
    if (i > 0 && left % 3 == 0) out.write(',');
    out.write(raw[i]);
  }
  return out.toString();
}
