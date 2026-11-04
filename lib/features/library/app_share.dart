import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/library/bundle_transfer.dart';
import 'package:social_save/features/library/bundle_ui.dart';
import 'package:social_save/features/library/nearby_service.dart';

/// One launchable app on this phone, with the APK files a send can use.
class PhoneApp {
  const PhoneApp({
    required this.name,
    required this.packageName,
    required this.version,
    required this.size,
    required this.system,
    required this.iconPath,
    required this.apkPaths,
  });

  final String name;
  final String packageName;
  final String version;
  final int size;
  final bool system;
  final String iconPath;
  final List<String> apkPaths;

  static PhoneApp? parse(Map<Object?, Object?> raw) {
    final name = (raw['name'] as String?)?.trim() ?? '';
    final packageName = (raw['package'] as String?)?.trim() ?? '';
    final apks = (raw['apks'] as List?)?.whereType<String>().where((path) => path.isNotEmpty).toList() ?? const <String>[];
    if (name.isEmpty || packageName.isEmpty || apks.isEmpty) return null;
    return PhoneApp(
      name: name,
      packageName: packageName,
      version: (raw['version'] as String?)?.trim() ?? '',
      size: (raw['size'] as num?)?.toInt() ?? 0,
      system: raw['system'] == true,
      iconPath: (raw['icon'] as String?) ?? '',
      apkPaths: apks,
    );
  }
}

/// File name safe for the folder a receiver saves.
String safeAppFileName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final cut = cleaned.length > 80 ? cleaned.substring(0, 80).trim() : cleaned;
  return cut.isEmpty ? 'app' : cut;
}

/// Builds the nearby bundle for the selected apps. One app with a single APK
/// is sent as "Name.apk". Several files keep each app in its own folder.
SendBundle? bundleForApps(List<PhoneApp> apps) {
  final items = <SendItem>[];
  final used = <String>{};
  String unique(String rel) {
    var name = rel;
    var i = 2;
    while (!used.add(name.toLowerCase())) {
      final slash = rel.lastIndexOf('/');
      final dot = rel.lastIndexOf('.');
      name = dot > slash ? '${rel.substring(0, dot)} ($i)${rel.substring(dot)}' : '$rel ($i)';
      i++;
    }
    return name;
  }

  for (final app in apps) {
    final label = safeAppFileName(app.name);
    final many = apps.length > 1 || app.apkPaths.length > 1;
    for (final path in app.apkPaths) {
      final file = File(path);
      if (!file.existsSync()) continue;
      final ext = p.extension(path).isEmpty ? '.apk' : p.extension(path);
      final rel = many ? '$label/${p.basename(path)}' : '$label$ext';
      items.add(SendItem(file, unique(rel), file.lengthSync()));
    }
  }
  if (items.isEmpty) return null;
  final label = apps.length == 1 ? apps.single.name : '${apps.length} apps';
  final folder = apps.length > 1 || apps.single.apkPaths.length > 1;
  return SendBundle(label, items, isFolder: folder);
}

/// Scan of the phone's apps. Started from Home so the list is ready to send.
class InstalledApps {
  InstalledApps._();

  static const _channel = MethodChannel('socialsave/media');
  static List<PhoneApp>? cached;
  static final results = ValueNotifier<List<PhoneApp>?>(null);
  static final scanning = ValueNotifier<bool>(false);
  static Future<List<PhoneApp>> Function()? debugLoader;
  static Future<List<PhoneApp>>? _flight;

  static Future<List<PhoneApp>> warm() => load();

  static Future<List<PhoneApp>> load({bool force = false}) {
    if (!Plat.isAndroid && debugLoader == null) {
      return Future.value(_publish(cached ?? const []));
    }
    if (!force) {
      final running = _flight;
      if (running != null) return running;
      final ready = cached;
      if (ready != null) return Future.value(_publish(ready));
    } else if (_flight != null) {
      return _flight!;
    }
    scanning.value = true;
    final future = _fetch();
    _flight = future;
    return future;
  }

  static List<PhoneApp> _publish(List<PhoneApp> apps) {
    cached = apps;
    results.value = apps;
    return apps;
  }

  static Future<List<PhoneApp>> _fetch() async {
    try {
      await Future<void>.value();
      final loader = debugLoader;
      if (loader != null) return _publish(await loader());
      final raw = await _channel.invokeListMethod<Map<Object?, Object?>>('installedApps');
      final apps = <PhoneApp>[];
      for (final row in raw ?? const <Map<Object?, Object?>>[]) {
        final app = PhoneApp.parse(row);
        if (app != null) apps.add(app);
      }
      apps.sort((a, b) {
        if (a.system != b.system) return a.system ? 1 : -1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return _publish(apps);
    } catch (_) {
      return _publish(cached ?? const []);
    } finally {
      _flight = null;
      scanning.value = false;
    }
  }
}

/// Apps already on this phone. Pick one or more and send them nearby.
class AppShareScreen extends StatefulWidget {
  const AppShareScreen({super.key, this.device});

  final NearbyDevice? device;

  @override
  State<AppShareScreen> createState() => _AppShareScreenState();
}

class _AppShareScreenState extends State<AppShareScreen> {
  final _query = TextEditingController();
  final _selected = <String>{};
  var _system = false;

  @override
  void initState() {
    super.initState();
    unawaited(InstalledApps.load());
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<PhoneApp> _shown(List<PhoneApp> apps) {
    final q = _query.text.trim().toLowerCase();
    return [
      for (final app in apps)
        if ((_system || !app.system) && (q.isEmpty || app.name.toLowerCase().contains(q) || app.packageName.toLowerCase().contains(q))) app,
    ];
  }

  Future<void> _send(List<PhoneApp> shown) async {
    final chosen = [for (final app in shown) if (_selected.contains(app.packageName)) app];
    if (chosen.isEmpty) return;
    final bundle = bundleForApps(chosen);
    if (bundle == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not read those apps.')));
      return;
    }
    final device = widget.device;
    if (device != null) {
      await sendBundleWithProgress(context, bundle, device);
    } else if (mounted) {
      await chooseTargetAndSend(context, bundle);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Plat.isAndroid && InstalledApps.debugLoader == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Apps')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('Apps on a phone are shared from the Android app.', textAlign: TextAlign.center),
          ),
        ),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Apps'),
        actions: [
          IconButton(
            tooltip: 'Scan again',
            onPressed: () => InstalledApps.load(force: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ValueListenableBuilder<bool>(
        valueListenable: InstalledApps.scanning,
        builder: (context, scanning, _) => ValueListenableBuilder<List<PhoneApp>?>(
          valueListenable: InstalledApps.results,
          builder: (context, apps, _) {
            final list = apps;
            if (list == null) {
              return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Scanning apps on this phone…'),
              ]));
            }
            final shown = _shown(list);
            final allSelected = shown.isNotEmpty && shown.every((app) => _selected.contains(app.packageName));
            final picked = shown.where((app) => _selected.contains(app.packageName)).toList();
            final pickedBytes = picked.fold<int>(0, (sum, app) => sum + app.size);
            return Column(
              children: [
                if (scanning) const LinearProgressIndicator(minHeight: 2),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: TextField(
                    key: const ValueKey('app-search'),
                    controller: _query,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      hintText: 'Search apps',
                      prefixIcon: Icon(Icons.search_rounded),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                SwitchListTile(
                  key: const ValueKey('app-system'),
                  value: _system,
                  onChanged: (v) => setState(() => _system = v),
                  title: const Text('System apps'),
                  subtitle: Text(scanning ? 'Scanning…' : () {
                    final ready = list.where((app) => !app.system).length;
                    return '$ready ${ready == 1 ? 'app' : 'apps'} ready to send';
                  }()),
                ),
                if (shown.isNotEmpty)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      key: const ValueKey('app-all'),
                      onPressed: () => setState(() {
                        if (allSelected) {
                          for (final app in shown) {
                            _selected.remove(app.packageName);
                          }
                        } else {
                          for (final app in shown) {
                            _selected.add(app.packageName);
                          }
                        }
                      }),
                      child: Text(allSelected ? 'Clear' : 'Select all'),
                    ),
                  ),
                Expanded(
                  child: shown.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              list.isEmpty ? 'No apps found on this phone.' : 'No apps match that search.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: shown.length,
                          itemBuilder: (context, index) {
                            final app = shown[index];
                            final on = _selected.contains(app.packageName);
                            return ListTile(
                              key: ValueKey('app-row-${app.packageName}'),
                              selected: on,
                              leading: _AppIcon(path: app.iconPath),
                              title: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                [sizeLabel(app.size), if (app.version.isNotEmpty) app.version].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Checkbox(
                                value: on,
                                onChanged: (_) => setState(() {
                                  if (!_selected.remove(app.packageName)) _selected.add(app.packageName);
                                }),
                              ),
                              onTap: () => setState(() {
                                if (!_selected.remove(app.packageName)) _selected.add(app.packageName);
                              }),
                            );
                          },
                        ),
                ),
                if (picked.isNotEmpty)
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${picked.length} ${picked.length == 1 ? 'app' : 'apps'} · ${sizeLabel(pickedBytes)}',
                              style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
                            ),
                          ),
                          FilledButton.icon(
                            key: const ValueKey('app-send'),
                            onPressed: () => _send(shown),
                            icon: const Icon(Icons.send_rounded),
                            label: Text(widget.device == null ? 'Send' : 'Send to ${widget.device!.name}'),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final file = path.isEmpty ? null : File(path);
    if (file == null || !file.existsSync()) {
      return CircleAvatar(
        backgroundColor: scheme.secondaryContainer,
        child: Icon(Icons.android_rounded, color: scheme.onSecondaryContainer),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.file(
        file,
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Icon(Icons.android_rounded, color: scheme.primary),
      ),
    );
  }
}
