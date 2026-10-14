import 'dart:math' as math;
import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart' show getDirectoryPath;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/platform/desktop_support.dart';
import 'package:social_save/core/platform/phone_body.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/library/device_media.dart';
import 'package:social_save/features/library/library_catalog.dart';
import 'package:social_save/features/library/phone_handoff.dart';
import 'package:social_save/features/library/summarize_sheet.dart';
import 'package:social_save/features/player/presentation/screens/in_app_player_screen.dart';
import 'package:social_save/features/library/vault_service.dart';
import 'package:social_save/shared/routing/app_router.dart' show debugOpenVault, debugOpenMenu;
import 'package:social_save/shared/widgets/skeleton.dart';
import 'package:social_save/features/player/open_player.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/widgets/empty_state.dart';
import 'package:social_save/shared/widgets/page_layout.dart';
import 'package:social_save/shared/widgets/local_video_thumb.dart';

double _libraryGutter(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (width >= 1100) return 32;
  if (width >= 840) return 24;
  return 16;
}

final vaultServiceProvider = Provider<VaultService>(
  (ref) => throw StateError('vaultServiceProvider must be overridden'),
);

final vaultUnlockedProvider = StateProvider<bool>((ref) => false);

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with WidgetsBindingObserver {
  int _tab = debugOpenVault ? 1 : 0;
  bool _loading = true;
  String? _error;
  String _query = '';
  String _platform = 'All';
  bool _favoritesOnly = false;
  String? _collection;
  List<DeviceVideo> _device = [];
  final Set<String> _selected = {};
  bool _selectMode = false;
  List<VaultItem> _vault = [];
  final Map<String, String> _vaultPaths = {};
  PlayerSession? _docked;
  bool _scanning = false;
  StreamSubscription<List<DeviceVideo>>? _scanSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      ref.read(vaultUnlockedProvider.notifier).state = false;
    }
  }

  Future<void> _reload({bool rescan = false}) async {
    if (DesktopSupport.isWindows) {
      await _reloadWindows(rescan: rescan);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    var allowed = true;
    if (!DesktopSupport.isWindows) {
      final videos = await Permission.videos.request();
      final storage = await Permission.storage.request();
      allowed =
          videos.isGranted || videos.isLimited || storage.isGranted || storage.isLimited;
    }
    try {
      final device = await DeviceMediaService().listVideos();
      final vaultService = ref.read(vaultServiceProvider);
      final vault = await vaultService.list();
      final vaultPaths = <String, String>{};
      for (final item in vault) {
        vaultPaths[item.id] = (await vaultService.fileFor(item)).path;
      }
      if (!mounted) return;
      setState(() {
        _device = device;
        _vault = vault;
        _vaultPaths
          ..clear()
          ..addAll(vaultPaths);
        _loading = false;
        _error = !allowed && device.isEmpty
            ? 'Allow video access so SocialSave can play files already on this phone.'
            : null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = DesktopSupport.isWindows
            ? 'Could not load videos on this PC.'
            : 'Could not load videos on this phone.';
        _loading = false;
      });
    }
  }

  /// Windows: every video in the PC's usual folders, streamed in as each
  /// folder finishes. The finished list is cached until Refresh.
  Future<void> _reloadWindows({bool rescan = false}) async {
    final media = DeviceMediaService();
    final cached = media.cachedWindows;
    setState(() {
      _error = null;
      if (cached != null && !rescan) {
        _device = cached;
        _loading = false;
      } else if (_device.isEmpty) {
        _loading = true;
      }
    });
    try {
      final vaultService = ref.read(vaultServiceProvider);
      final vault = await vaultService.list();
      final vaultPaths = <String, String>{};
      for (final item in vault) {
        vaultPaths[item.id] = (await vaultService.fileFor(item)).path;
      }
      if (!mounted) return;
      setState(() {
        _vault = vault;
        _vaultPaths
          ..clear()
          ..addAll(vaultPaths);
      });
    } catch (_) {}
    if (cached != null && !rescan) return;
    await _scanSub?.cancel();
    if (!mounted) return;
    setState(() => _scanning = true);
    _scanSub = media.scanWindows().listen(
      (batch) {
        if (!mounted) return;
        setState(() {
          _device = batch;
          _loading = false;
        });
        // Screenshot hook (`--open-menu`): open the first video's menu once.
        if (debugOpenMenu && batch.isNotEmpty) {
          debugOpenMenu = false;
          Future<void>.delayed(const Duration(seconds: 2), () {
            if (mounted && _device.isNotEmpty) _deviceActions(_device.first);
          });
        }
      },
      onError: (_) {
        if (!mounted) return;
        setState(() {
          _scanning = false;
          _loading = false;
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _scanning = false;
          _loading = false;
        });
      },
    );
  }

  Future<void> _manageWindowsFolders() async {
    final defaults = await DesktopSupport.defaultFolders();
    var extra = [...await DesktopSupport.extraFolders()];
    if (!mounted) return;
    var changed = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.8,
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                const ListTile(
                  title: Text('Video folders on this PC'),
                  subtitle: Text('SocialSave looks for videos in these folders and the folders inside them.'),
                ),
                for (final folder in defaults)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.folder_special_outlined),
                    title: Text(folder),
                    subtitle: const Text('Default'),
                  ),
                for (final folder in extra)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(folder),
                    subtitle: const Text('Added by you'),
                    trailing: IconButton(
                      tooltip: 'Remove folder',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () async {
                        extra = extra.where((item) => item != folder).toList();
                        await DesktopSupport.setExtraFolders(extra);
                        changed = true;
                        setSheet(() {});
                      },
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: FilledButton.icon(
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Add folder'),
                    onPressed: () async {
                      final picked = await getDirectoryPath(confirmButtonText: 'Add folder');
                      if (picked == null || picked.isEmpty) return;
                      final lower = picked.toLowerCase();
                      if (extra.any((item) => item.toLowerCase() == lower) ||
                          defaults.any((item) => item.toLowerCase() == lower)) {
                        return;
                      }
                      extra = [...extra, picked];
                      await DesktopSupport.setExtraFolders(extra);
                      changed = true;
                      setSheet(() {});
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (changed && mounted) await _reload(rescan: true);
  }

  Future<void> _playDevice(DeviceVideo video) async {
    final path = await DeviceMediaService().resolvePlayablePath(video);
    if (!mounted) return;
    if (path == null || !File(path).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This video could not be opened.')),
      );
      return;
    }
    final queue = _device
        .map(
          (item) => PlayerQueueItem(
            title: item.title,
            deviceId: item.id,
            devicePath: item.path,
            deviceUri: item.uri,
            filePath: item.id == video.id ? path : item.path,
          ),
        )
        .toList();
    final index = _device.indexWhere((item) => item.id == video.id);
    await _openSession(
      PlayerSession(
        title: video.title,
        platform: SocialPlatform.direct,
        filePath: path,
        queue: queue,
        queueIndex: index < 0 ? 0 : index,
        heroTag: 'library-${video.id}',
      ),
    );
  }

  Future<void> _openSession(PlayerSession session) async {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    if (wide) {
      setState(() => _docked = session);
      return;
    }
    await openPreviewPlayer(context, session);
  }

  Future<void> _playVault(VaultItem item) async {
    final file = await ref.read(vaultServiceProvider).fileFor(item);
    if (!mounted) return;
    if (!file.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This vault file is missing.')),
      );
      return;
    }
    final queue = _vault
        .map(
          (entry) => PlayerQueueItem(
            title: entry.title,
            filePath: _vaultPaths[entry.id],
            isVault: true,
          ),
        )
        .toList();
    final index = _vault.indexWhere((entry) => entry.id == item.id);
    await _openSession(
      PlayerSession(
        title: item.title,
        platform: SocialPlatform.direct,
        filePath: file.path,
        isVault: true,
        queue: queue,
        queueIndex: index < 0 ? 0 : index,
      ),
    );
  }

  Future<void> _addToVault(DeviceVideo video, {required bool move}) async {
    final path = await DeviceMediaService().resolvePlayablePath(video);
    if (path == null) return;
    await ref.read(vaultServiceProvider).importFile(
          sourcePath: path,
          title: video.title,
        );
    if (move) {
      await DeviceMediaService().deletePublic(video);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(move ? 'Moved to vault' : 'Copied to vault'),
      ),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.delete): () {
          if (_tab != 0 || _selected.isEmpty) return;
          _deleteVideos(_device.where((v) => _selected.contains(v.id)).toList());
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_selectMode || _selected.isNotEmpty) {
            setState(() {
              _selected.clear();
              _selectMode = false;
            });
          }
        },
      },
      child: Focus(autofocus: DesktopSupport.isWindows, child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    final gutter = _libraryGutter(context);
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Library', style: pageTitleStyle(context)),
        if (isDesktopShell(context))
          Text(
            DesktopSupport.isWindows ? 'Videos on this PC' : 'Videos on this device',
            style: TextStyle(
              fontSize: 13,
              height: 1.3,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
    final actions = <Widget>[
      if (_tab == 0)
        TextButton.icon(
          key: const ValueKey('library-select'),
          onPressed: () => setState(() {
            _selectMode = !_selectMode;
            if (!_selectMode) _selected.clear();
          }),
          icon: Icon(_selectMode ? Icons.close_rounded : Icons.checklist_rounded, size: 20),
          label: Text(_selectMode ? 'Done' : 'Select'),
        ),
      FilledButton.tonalIcon(
        key: const ValueKey('library-share'),
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        onPressed: () => showNearbySheet(
          context,
          onSend: _pickLibraryVideoToSend,
          pickFile: _chooseFileToSend,
          onReceived: () => _reload(rescan: DesktopSupport.isWindows),
        ),
        icon: const Icon(Icons.wifi_tethering_rounded, size: 18),
        label: const Text('Share'),
      ),
      if (DesktopSupport.isWindows)
        IconButton(
          tooltip: 'Video folders',
          onPressed: _manageWindowsFolders,
          icon: const Icon(Icons.create_new_folder_outlined),
        ),
      IconButton(
        tooltip: 'Refresh',
        onPressed: () => _reload(rescan: true),
        icon: const Icon(Icons.refresh_rounded),
      ),
    ];
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth < 520) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        title,
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(children: actions),
                        ),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: title),
                      ...actions,
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: gutter),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 640;
                  final switcher = SegmentedButton<int>(
                    // On a wide library row, the two tabs share a wider track
                    // so they reach a little further into the middle.
                    expandedInsets: wide ? EdgeInsets.zero : null,
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      minimumSize: const Size(72, 42),
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    ),
                    segments: [
                      ButtonSegment(
                        value: 0,
                        icon: Icon(DesktopSupport.isWindows ? Icons.computer_rounded : Icons.smartphone_rounded, size: 18),
                        label: Text(DesktopSupport.isWindows ? 'This PC' : 'This phone'),
                      ),
                      const ButtonSegment(value: 1, icon: Icon(Icons.lock_rounded, size: 18), label: Text('Vault')),
                    ],
                    selected: {_tab},
                    onSelectionChanged: (value) => _selectTab(value.first),
                  );
                  final search = TextField(
                    onChanged: (value) => setState(() => _query = value),
                    decoration: const InputDecoration(
                      hintText: 'Search by title',
                      prefixIcon: Icon(Icons.search_rounded),
                      isDense: true,
                    ),
                  );
                  if (!wide) {
                    return Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        switcher,
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child: search,
                        ),
                      ],
                    );
                  }
                  final switchWidth = (constraints.maxWidth * 0.42).clamp(300.0, 440.0);
                  final searchWidth = math.min(360.0, constraints.maxWidth - switchWidth - 16);
                  return Row(
                    children: [
                      SizedBox(width: switchWidth, child: switcher),
                      const SizedBox(width: 16),
                      SizedBox(width: searchWidth, child: search),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: gutter),
                children: [
                  for (final name in const ['All', 'YouTube', 'TikTok', 'Instagram', 'Facebook', 'X'])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(name),
                        selected: _platform == name,
                        onSelected: (_) => setState(() => _platform = name),
                      ),
                    ),
                  const SizedBox(height: 24, child: VerticalDivider(width: 16)),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: const Text('Favorites'),
                      selected: _favoritesOnly,
                      onSelected: (value) => setState(() => _favoritesOnly = value),
                    ),
                  ),
                  for (final name in ref.watch(libraryCatalogProvider).collectionNames)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(name),
                        selected: _collection == name,
                        onSelected: (_) => setState(() {
                          _collection = _collection == name ? null : name;
                        }),
                      ),
                    ),
                  ActionChip(
                    label: const Text('New collection'),
                    onPressed: _createCollection,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if ((_selectMode || _selected.isNotEmpty) && _tab == 0)
              Padding(
                padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 8),
                child: Material(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(16),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Cancel',
                        onPressed: () => setState(() {
                          _selected.clear();
                          _selectMode = false;
                        }),
                        icon: const Icon(Icons.close_rounded),
                      ),
                      Expanded(child: Text('${_selected.length} selected', style: const TextStyle(fontWeight: FontWeight.w700))),
                      TextButton(
                        onPressed: () => setState(() => _selected.addAll(_device.where(_matchesVideo).map((v) => v.id))),
                        child: const Text('Select all'),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        onPressed: () => _deleteVideos(_device.where((v) => _selected.contains(v.id)).toList()),
                        icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
                      ),
                    ],
                  ),
                ),
              ),
            if (DesktopSupport.isWindows && _scanning && _tab == 0)
              Padding(
                padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 8),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Looking for videos on this PC… ${_device.length} found',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final twoPane = MediaQuery.sizeOf(context).width >= 900;
                  final list = _loading
                      ? const SkeletonGrid()
                      : _error != null
                          ? EmptyState(
                              icon: Icons.videocam_off_outlined,
                              title: 'Cannot open library',
                              message: _error!,
                              action: FilledButton.icon(
                                onPressed: () => _reload(rescan: true),
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('Try again'),
                              ),
                            )
                          : _tab == 0
                              ? _DeviceList(
                                  selected: _selected,
                                  selecting: _selectMode || _selected.isNotEmpty,
                                  onDelete: (video) => _deleteVideos([video]),
                                  onToggle: _toggleSelect,
                                  videos: _device.where(_matchesVideo).toList(),
                                  onPlay: _playDevice,
                                  onVault: (video) => _confirmVault(video),
                                  onActions: _deviceActions,
                                  onSend: _sendDevice,
                                )
                              : _VaultGate(
                                  items: _vault.where(_matchesVault).toList(),
                                  paths: _vaultPaths,
                                  onPlay: _playVault,
                                  onActions: _vaultItemActions,
                                  onReload: _reload,
                                );
                  if (!twoPane) return list;
                  final docked = _docked;
                  return Row(
                    children: [
                      Expanded(child: list),
                      const VerticalDivider(width: 1),
                      SizedBox(
                        width: (constraints.maxWidth * 0.48).clamp(320.0, 640.0),
                        child: docked == null
                            ? const EmptyState(
                                icon: Icons.play_circle_outline_rounded,
                                title: 'Nothing playing',
                                message: 'Choose a video to play it beside the library.',
                              )
                            : InAppPlayerScreen(
                                key: ValueKey(
                                  '${docked.filePath ?? docked.title}-${docked.queueIndex}',
                                ),
                                session: docked,
                                embedded: true,
                                onClose: () => setState(() => _docked = null),
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _matchesVideo(DeviceVideo video) {
    if (!_matchesText('${video.title} ${video.path ?? ''}')) return false;
    final catalog = ref.read(libraryCatalogProvider);
    final key = 'device:${video.id}';
    if (_favoritesOnly && !catalog.isFavorite(key)) return false;
    final collection = _collection;
    if (collection != null && !catalog.inCollection(collection, key)) return false;
    return true;
  }

  bool _matchesVault(VaultItem item) {
    return _matchesText(item.title);
  }

  bool _matchesText(String value) {
    final query = _query.trim().toLowerCase();
    final blob = value.toLowerCase();
    if (query.isNotEmpty && !blob.contains(query)) return false;
    if (_platform == 'All') return true;
    return blob.contains(_platform.toLowerCase());
  }

  void _selectTab(int value) => setState(() => _tab = value);

  Future<void> _vaultItemActions(VaultItem item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Take out of vault'),
              subtitle: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('Move to Library'),
              subtitle: Text(
                DesktopSupport.isWindows
                    ? 'Put it back under This PC and remove it from the vault'
                    : 'Put it back in On this phone and remove it from the vault',
              ),
              onTap: () => Navigator.pop(context, 'move'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('Keep a copy in Library'),
              subtitle: Text(
                DesktopSupport.isWindows
                    ? 'Show it under This PC and keep the vault copy locked'
                    : 'Show it in On this phone and keep the vault copy locked',
              ),
              onTap: () => Navigator.pop(context, 'copy'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: const Text('Delete forever'),
              subtitle: const Text('Remove it from the vault without putting it back in Gallery'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'delete') {
      await _deleteVaultItem(item);
      return;
    }
    if (action == 'rename') {
      final controller = TextEditingController(text: item.title);
      final name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Rename'),
          content: TextField(controller: controller, autofocus: true),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      controller.dispose();
      if (name == null || name.isEmpty) return;
      await ref.read(vaultServiceProvider).rename(item, name);
      await _reload();
      return;
    }
    if (action != 'move' && action != 'copy') return;
    try {
      await ref.read(vaultServiceProvider).restoreToGallery(item);
      if (action == 'move') {
        await ref.read(vaultServiceProvider).delete(item);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            action == 'copy'
                ? 'Copied to Library. The vault copy is still locked.'
                : 'Moved to Library. It is no longer in the vault.',
          ),
        ),
      );
      setState(() => _tab = 0);
      await _reload();
    } on StateError catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not move this video back to Library.')),
      );
    }
  }

  Future<void> _deleteVaultItem(VaultItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete forever?'),
        content: Text(
          '“${item.title}” will be removed from the vault and will not be put back in Gallery. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(vaultServiceProvider).delete(item);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Removed from vault.')),
    );
    await _reload();
  }

  Future<void> _sendDevice(DeviceVideo video) async {
    final path = await DeviceMediaService().resolvePlayablePath(video);
    if (path == null || !mounted) return;
    await showSendToPhone(context, File(path), video.title);
  }

  /// For a tapped nearby device: choose from this Library or browse.
  Future<File?> _chooseFileToSend() async {
    final videos = _device.where(_matchesVideo).toList();
    final choice = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: Column(
            children: [
              const ListTile(title: Text('Send which video?')),
              ListTile(
                leading: const Icon(Icons.folder_open_rounded),
                title: const Text('Browse for a file…'),
                onTap: () => Navigator.pop(context, 'browse'),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: videos.length,
                  itemBuilder: (context, i) => ListTile(
                    leading: const Icon(Icons.movie_outlined),
                    title: Text(videos[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.pop(context, videos[i]),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null) return null;
    if (choice is DeviceVideo) {
      final path = await DeviceMediaService().resolvePlayablePath(choice);
      return path == null ? null : File(path);
    }
    return pickVideoFile();
  }

  /// "Send video" in the Nearby share bar: choose from this Library,
  /// or browse for any file.
  Future<void> _pickLibraryVideoToSend() async {
    final videos = _device.where(_matchesVideo).toList();
    final choice = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.7,
          child: Column(
            children: [
              const ListTile(
                title: Text('Send which video?'),
                subtitle: Text('The other phone or PC can watch it or save a copy.'),
              ),
              ListTile(
                leading: const Icon(Icons.folder_open_rounded),
                title: const Text('Browse for a file…'),
                onTap: () => Navigator.pop(context, 'browse'),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: videos.length,
                  itemBuilder: (context, i) => ListTile(
                    leading: const Icon(Icons.movie_outlined),
                    title: Text(videos[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.pop(context, videos[i]),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice is DeviceVideo) {
      await _sendDevice(choice);
    } else {
      await pickAndSend(context);
    }
  }

  Future<void> _deviceActions(DeviceVideo video) async {
    final action = await _showItemMenu(
      builder: (context) => [
            ListTile(
              title: Text(video.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text(_durationLabel((video.durationMs / 1000).round(), video.size)),
              trailing: IconButton(
                tooltip: 'Delete',
                icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
                onPressed: () => Navigator.pop(context, 'delete'),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded),
              title: const Text('Play'),
              onTap: () => Navigator.pop(context, 'play'),
            ),
            ListTile(
              key: const ValueKey('menu-delete'),
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: Text(
                DesktopSupport.isWindows ? 'Delete (Recycle Bin)' : 'Delete from phone',
                style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w600),
              ),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () => Navigator.pop(context, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Share file'),
              onTap: () => Navigator.pop(context, 'share'),
            ),
            if (DesktopSupport.isWindows)
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: const Text('Show in folder'),
                subtitle: Text(video.path ?? ''),
                onTap: () => Navigator.pop(context, 'reveal'),
              ),
            if (!DesktopSupport.isWindows)
              ListTile(
                leading: const Icon(Icons.tv_rounded),
                title: const Text('Play on TV'),
                subtitle: const Text('Opens the video already on this phone'),
                onTap: () => Navigator.pop(context, 'tv'),
              ),
            ListTile(
              leading: const Icon(Icons.qr_code_rounded),
              title: const Text('Send to another device'),
              subtitle: const Text('Phone or PC on this Wi-Fi: QR or 6-letter code. Watch or save.'),
              onTap: () => Navigator.pop(context, 'handoff'),
            ),
            ListTile(
              leading: const Icon(Icons.phonelink_rounded),
              title: const Text('Hold phones together'),
              subtitle: const Text('Quick Share between the two phones'),
              onTap: () => Navigator.pop(context, 'near'),
            ),
            ListTile(
              leading: const Icon(Icons.ring_volume_outlined),
              title: const Text('Use 30 seconds as a sound'),
              subtitle: const Text('Ringtone, notification, or alarm'),
              onTap: () => Navigator.pop(context, 'sound'),
            ),
            ListTile(
              leading: Icon(
                ref.read(libraryCatalogProvider).isFavorite('device:${video.id}')
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
              ),
              title: const Text('Favorite'),
              onTap: () => Navigator.pop(context, 'favorite'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Add to collection'),
              onTap: () => Navigator.pop(context, 'collection'),
            ),
            ListTile(
              leading: const Icon(Icons.notes_outlined),
              title: const Text('Note'),
              onTap: () => Navigator.pop(context, 'note'),
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('Summarize'),
              onTap: () => Navigator.pop(context, 'summary'),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Details'),
              onTap: () => Navigator.pop(context, 'details'),
            ),
            ListTile(
              leading: const Icon(Icons.check_box_outlined),
              title: const Text('Select (for deleting several)'),
              onTap: () => Navigator.pop(context, 'select'),
            ),
          ],
    );
    if (!mounted || action == null) return;
    if (action == 'play') {
      await _playDevice(video);
      return;
    }
    if (action == 'rename') {
      await _renameDevice(video);
      return;
    }
    if (action == 'reveal') {
      final path = video.path;
      if (path != null) await DesktopSupport.revealInFolder(path);
      return;
    }
    if (action == 'share' || action == 'near' || action == 'tv' || action == 'handoff' || action == 'sound') {
      final path = await DeviceMediaService().resolvePlayablePath(video);
      if (path == null || !mounted) return;
      if (action == 'share' || action == 'near') {
        await Share.shareXFiles([XFile(path)], text: video.title);
        return;
      }
      if (action == 'tv') {
        final ok = await PhoneBody.playOnTv(path: path, title: video.title);
        if (!mounted) return;
        if (!ok) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No TV app on this phone could open the video.')),
          );
        }
        return;
      }
      if (action == 'handoff') {
        await showSendToPhone(context, File(path), video.title);
        return;
      }
      await showSoundClip(context, path);
      return;
    }
    if (action == 'favorite') {
      await ref.read(libraryCatalogProvider.notifier).toggleFavorite('device:${video.id}');
      return;
    }
    if (action == 'collection') {
      await _addVideoToCollection(video);
      return;
    }
    if (action == 'note') {
      await _editNote('device:${video.id}');
      return;
    }
    if (action == 'summary') {
      final record = await _recordForPath(video.path);
      if (!mounted) return;
      await showVideoSummary(
        context,
        ref,
        title: video.title,
        author: record?.author,
        sourceUrl: record?.sourceUrl,
      );
      return;
    }
    if (action == 'details') {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(video.title),
          content: Text(
            '${_durationLabel((video.durationMs / 1000).round(), video.size)}\n${video.path ?? video.uri ?? ''}\n${ref.read(libraryCatalogProvider).notes['device:${video.id}'] ?? ''}',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
        ),
      );
      return;
    }
    if (action == 'select') {
      setState(() {
        _selectMode = true;
        _selected.add(video.id);
      });
      return;
    }
    if (action == 'delete') {
      await _deleteVideos([video]);
    }
  }

  /// Item menu that always fits: a centred scrollable dialog on PC, a
  /// scrollable sheet (max 85% of the screen) on phones.
  Future<String?> _showItemMenu({required List<Widget> Function(BuildContext) builder}) {
    final size = MediaQuery.sizeOf(context);
    if (DesktopSupport.isWindows || size.width >= 700) {
      return showDialog<String>(
        context: context,
        builder: (context) => Dialog(
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 440, maxHeight: size.height * 0.85),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(mainAxisSize: MainAxisSize.min, children: builder(context)),
            ),
          ),
        ),
      );
    }
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(maxHeight: size.height * 0.85),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: builder(context)),
        ),
      ),
    );
  }

  void _toggleSelect(DeviceVideo video) {
    setState(() {
      if (!_selected.remove(video.id)) _selected.add(video.id);
    });
  }

  /// Confirms, deletes (Recycle Bin on PC), drops matching download records
  /// and refreshes the list.
  Future<void> _deleteVideos(List<DeviceVideo> videos) async {
    if (videos.isEmpty) return;
    final what = videos.length == 1 ? '“${videos.first.title}”' : '${videos.length} videos';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
        title: Text('Delete $what?'),
        content: Text(DesktopSupport.isWindows
            ? 'This removes the file${videos.length == 1 ? '' : 's'} from your device (moved to the Recycle Bin).'
            : 'This removes the file${videos.length == 1 ? '' : 's'} from your device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final deleted = await DeviceMediaService().deleteMany(videos);
    // Forget download records for these files (and the app's own copy).
    try {
      final repo = ref.read(downloadsRepositoryProvider);
      // Only files that are really gone (the user may decline the system prompt).
      final gonePaths = [for (final v in videos) if (v.path != null && !File(v.path!).existsSync()) v.path!];
      final names = {for (final p in gonePaths) p.split(Platform.pathSeparator).last.split('/').last};
      final paths = gonePaths.toSet();
      for (final record in await repo.getAll()) {
        final local = record.localPath;
        if (local == null || local.isEmpty) continue;
        final name = local.split(Platform.pathSeparator).last.split('/').last;
        final ownCopy = local.contains('/Android/data/') && names.contains(name);
        if (paths.contains(local) || ownCopy) {
          await repo.delete(record.id, deleteFile: ownCopy);
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(deleted >= videos.length
          ? 'Deleted ${videos.length == 1 ? '1 video' : '${videos.length} videos'}${DesktopSupport.isWindows ? ' (moved to the Recycle Bin)' : ''}.'
          : deleted == 0
              ? 'Nothing was deleted.'
              : 'Deleted $deleted of ${videos.length}. The rest were kept.'),
    ));
    await _reload(rescan: DesktopSupport.isWindows);
  }

  Future<void> _renameDevice(DeviceVideo video) async {
    final controller = TextEditingController(text: video.title);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    final ok = await DeviceMediaService().renamePublic(video, name);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'Renamed.' : 'Could not rename this video.')),
    );
    await _reload();
  }

  Future<void> _confirmVault(DeviceVideo video) async {
    final unlocked = await ensureVaultUnlocked(context, ref);
    if (!unlocked || !mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Add to vault'),
              subtitle: Text('Vault files stay inside SocialSave and need your PIN.'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('Copy to vault'),
              subtitle: Text(
                DesktopSupport.isWindows
                    ? 'Keep the original on this PC'
                    : 'Keep the original on this phone',
              ),
              onTap: () => Navigator.pop(context, 'copy'),
            ),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('Move to vault'),
              subtitle: Text(
                DesktopSupport.isWindows
                    ? 'Remove the original file and keep only the vault copy'
                    : 'Remove it from Gallery and Files',
              ),
              onTap: () => Navigator.pop(context, 'move'),
            ),
          ],
        ),
      ),
    );
    if (action == 'copy') await _addToVault(video, move: false);
    if (action == 'move') await _addToVault(video, move: true);
  }

  Future<void> _createCollection() async {
    final name = await _askText('New collection', 'Name');
    if (name == null || name.isEmpty) return;
    await ref.read(libraryCatalogProvider.notifier).createCollection(name);
    if (!mounted) return;
    setState(() => _collection = name.trim());
  }

  Future<void> _addVideoToCollection(DeviceVideo video) async {
    final catalog = ref.read(libraryCatalogProvider);
    final names = catalog.collectionNames;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final name in names)
              ListTile(
                title: Text(name),
                onTap: () => Navigator.pop(context, name),
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('New collection'),
              onTap: () => Navigator.pop(context, ''),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    var name = choice;
    if (name.isEmpty) {
      final created = await _askText('New collection', 'Name');
      if (created == null || created.isEmpty) return;
      name = created;
    }
    await ref.read(libraryCatalogProvider.notifier).addToCollection(name, 'device:${video.id}');
  }

  Future<void> _editNote(String key) async {
    final current = ref.read(libraryCatalogProvider).notes[key] ?? '';
    final note = await _askText('Note', 'A note for this video', initial: current);
    if (note == null) return;
    await ref.read(libraryCatalogProvider.notifier).setNote(key, note);
  }

  Future<String?> _askText(String title, String label, {String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(controller: controller, autofocus: true, decoration: InputDecoration(labelText: label)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  Future<DownloadRecord?> _recordForPath(String? path) async {
    if (path == null || path.isEmpty) return null;
    final records = await ref.read(downloadsRepositoryProvider).getAll();
    for (final record in records) {
      if (record.localPath == path) return record;
    }
    return null;
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({
    required this.selected,
    required this.selecting,
    required this.onDelete,
    required this.onToggle,
    required this.videos,
    required this.onPlay,
    required this.onVault,
    required this.onActions,
    required this.onSend,
  });

  final ValueChanged<DeviceVideo> onSend;
  final Set<String> selected;
  final bool selecting;
  final ValueChanged<DeviceVideo> onDelete;
  final ValueChanged<DeviceVideo> onToggle;
  final List<DeviceVideo> videos;
  final ValueChanged<DeviceVideo> onPlay;
  final ValueChanged<DeviceVideo> onVault;
  final ValueChanged<DeviceVideo> onActions;

  @override
  Widget build(BuildContext context) {
    if (videos.isEmpty) {
      if (DesktopSupport.isWindows) {
        return const EmptyState(
          icon: Icons.video_library_outlined,
          title: 'No videos found on this PC',
          message: 'Add a folder with the folder button above, or download a video, then refresh.',
        );
      }
      return const EmptyState(
        icon: Icons.video_library_outlined,
        title: 'No videos on this phone',
        message: 'Download a video or copy one onto the device, then refresh.',
      );
    }
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(_libraryGutter(context), 8, _libraryGutter(context), 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 240,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: videos.length,
      itemBuilder: (context, index) {
        final video = videos[index];
        final seconds = (video.durationMs / 1000).round();
        return _VideoCard(
          cacheKey: 'device-${video.id}',
          id: video.id,
          path: video.path,
          uri: video.uri,
          title: video.title,
          caption: DesktopSupport.isWindows
              ? _pcCaption(video)
              : _durationLabel(seconds, video.size),
          durationLabel: DesktopSupport.isWindows && seconds == 0 ? null : _clock(seconds),
          onTap: () => selecting ? onToggle(video) : onPlay(video),
          onLongPress: () => onToggle(video),
          heroTag: 'library-${video.id}',
          action: selecting
              ? Checkbox(
                  value: selected.contains(video.id),
                  onChanged: (_) => onToggle(video),
                  side: const BorderSide(color: Colors.white, width: 2),
                )
              : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Send to another device',
                visualDensity: VisualDensity.compact,
                onPressed: () => onSend(video),
                icon: const Icon(Icons.send_to_mobile_rounded, color: Colors.white),
              ),
              IconButton(
                tooltip: 'Add to vault',
                visualDensity: VisualDensity.compact,
                onPressed: () => onVault(video),
                icon: const Icon(Icons.lock_outline, color: Colors.white),
              ),
              IconButton(
                key: ValueKey('card-delete-${video.id}'),
                tooltip: 'Delete',
                visualDensity: VisualDensity.compact,
                onPressed: () => onDelete(video),
                icon: const Icon(Icons.delete_outline, color: Colors.white),
              ),
              IconButton(
                tooltip: 'More',
                visualDensity: VisualDensity.compact,
                onPressed: () => onActions(video),
                icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Windows: size and the folder the video is in.
String _pcCaption(DeviceVideo video) {
  final folder = video.folder ?? (video.path == null ? '' : File(video.path!).parent.path);
  final name = folder.isEmpty ? '' : folder.split(Platform.pathSeparator).last;
  final size = video.size <= 0 ? '' : '${(video.size / (1024 * 1024)).toStringAsFixed(1)} MB';
  return [size, if (name.isNotEmpty) name].where((part) => part.isNotEmpty).join('  •  ');
}

String _clock(int seconds) {
  final mins = seconds ~/ 60;
  final secs = (seconds % 60).toString().padLeft(2, '0');
  return '$mins:$secs';
}

String _durationLabel(int seconds, int size) {
  final clock = _clock(seconds);
  if (size <= 0) return clock;
  return '$clock  •  ${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _VideoCard extends StatelessWidget {
  const _VideoCard({
    required this.cacheKey,
    required this.title,
    required this.onTap,
    this.onLongPress,
    this.id,
    this.path,
    this.uri,
    this.caption,
    this.durationLabel,
    this.locked = false,
    this.action,
    this.heroTag,
  });

  final String cacheKey;
  final String title;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final String? id;
  final String? path;
  final String? uri;
  final String? caption;
  final String? durationLabel;
  final bool locked;
  final Widget? action;
  final String? heroTag;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.brightness == Brightness.dark
          ? const Color(0xCC1C2633)
          : const Color(0xCCFFFFFF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.55)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  HeroMode(
                    enabled: (ModalRoute.of(context)?.isCurrent ?? true) && heroTag != null,
                    child: Hero(
                      tag: heroTag ?? cacheKey,
                      child: LocalVideoThumb(
                        cacheKey: cacheKey,
                        id: id,
                        path: path,
                        uri: uri,
                        borderRadius: 0,
                      ),
                    ),
                  ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x33000000), Color(0x00000000), Color(0x66000000)],
                      ),
                    ),
                  ),
                  const Center(
                    child: CircleAvatar(
                      radius: 18,
                      backgroundColor: Color(0xCC000000),
                      child: Icon(Icons.play_arrow_rounded, color: Colors.white),
                    ),
                  ),
                  if (durationLabel != null)
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xCC000000),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          child: Text(
                            durationLabel!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (locked)
                    const Positioned(
                      left: 8,
                      top: 8,
                      child: Icon(Icons.lock_rounded, color: Colors.white, size: 18),
                    ),
                  if (action != null)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: action!,
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, height: 1.25),
                  ),
                  if (caption != null)
                    Text(
                      caption!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, height: 1.3, color: scheme.onSurfaceVariant),
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

class _VaultGate extends ConsumerWidget {
  const _VaultGate({
    required this.items,
    required this.paths,
    required this.onPlay,
    required this.onActions,
    required this.onReload,
  });

  final List<VaultItem> items;
  final Map<String, String> paths;
  final ValueChanged<VaultItem> onPlay;
  final ValueChanged<VaultItem> onActions;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unlocked = ref.watch(vaultUnlockedProvider);
    if (!unlocked) {
      return VaultLockPane(onUnlocked: onReload);
    }
    if (items.isEmpty) {
      return Column(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => ref.read(vaultUnlockedProvider.notifier).state = false,
              icon: const Icon(Icons.lock_rounded, size: 18),
              label: const Text('Lock'),
            ),
          ),
          const Expanded(
            child: EmptyState(
              icon: Icons.lock_outline,
              title: 'Vault is empty',
              message: 'From the other tab, use the lock action on a video to hide it behind your PIN.',
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton.icon(
              onPressed: () => ref.read(vaultUnlockedProvider.notifier).state = false,
              icon: const Icon(Icons.lock_rounded, size: 18),
              label: const Text('Lock'),
            ),
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: EdgeInsets.fromLTRB(_libraryGutter(context), 8, _libraryGutter(context), 24),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: MediaQuery.sizeOf(context).width >= 700 ? 3 : 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.78,
            ),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return _VideoCard(
                cacheKey: 'vault-${item.id}',
                path: paths[item.id],
                title: item.title,
                caption: '${(item.bytes / (1024 * 1024)).toStringAsFixed(1)} MB',
                locked: true,
                onTap: () => onPlay(item),
                onLongPress: () => onActions(item),
                action: IconButton(
                  tooltip: 'Move to Library',
                  onPressed: () => onActions(item),
                  icon: const Icon(Icons.lock_open_rounded, color: Colors.white),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class VaultLockPane extends ConsumerStatefulWidget {
  const VaultLockPane({super.key, this.onUnlocked});

  final VoidCallback? onUnlocked;

  @override
  ConsumerState<VaultLockPane> createState() => _VaultLockPaneState();
}

class _VaultLockPaneState extends ConsumerState<VaultLockPane> with SingleTickerProviderStateMixin {
  static const _length = 4;
  String _pin = '';
  String _first = '';
  bool _confirming = false;
  String? _error;
  final FocusNode _focus = FocusNode();
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void dispose() {
    _shake.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _wrong() {
    HapticFeedback.heavyImpact();
    HapticFeedback.vibrate();
    _shake.forward(from: 0);
  }

  Future<void> _press(String digit) async {
    if (_pin.length >= _length) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += digit;
      _error = null;
    });
    if (_pin.length == _length) {
      // Let the last dot fill before checking.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (mounted) await _submit(_pin);
    }
  }

  void _backspace() {
    if (_pin.isEmpty) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _error = null;
    });
  }

  void _cancel() {
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop(false);
  }

  Future<void> _submit(String pin) async {
    if (pin.length != _length || int.tryParse(pin) == null) {
      setState(() => _error = 'Use a 4-digit PIN.');
      return;
    }
    final vault = ref.read(vaultServiceProvider);
    await HapticFeedback.lightImpact();
    if (!vault.hasPin) {
      if (!_confirming) {
        setState(() {
          _first = pin;
          _pin = '';
          _confirming = true;
        });
        return;
      }
      if (pin != _first) {
        _wrong();
        setState(() {
          _error = 'Passcodes did not match. Try again.';
          _pin = '';
          _first = '';
          _confirming = false;
        });
        return;
      }
      await vault.setPin(pin);
      ref.read(vaultUnlockedProvider.notifier).state = true;
      widget.onUnlocked?.call();
      return;
    }
    if (vault.verifyPin(pin)) {
      ref.read(vaultUnlockedProvider.notifier).state = true;
      widget.onUnlocked?.call();
      return;
    }
    _wrong();
    setState(() {
      _error = 'Wrong passcode';
      _pin = '';
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final ch = event.character;
    if (ch != null && ch.length == 1 && '0123456789'.contains(ch)) {
      _press(ch);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace || key == LogicalKeyboardKey.delete) {
      _backspace();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (_pin.length == _length) _submit(_pin);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _cancel();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final vault = ref.watch(vaultServiceProvider);
    final creating = !vault.hasPin;
    final title = creating
        ? (_confirming ? 'Confirm Passcode' : 'Create Passcode')
        : 'Enter Passcode';
    final subtitle = _error ??
        (creating
            ? (_confirming ? 'Enter the same 4 digits again' : 'Choose 4 digits to lock your vault')
            : 'Unlock your SocialSave vault');
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF14202E), Color(0xFF0A1118)],
          ),
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            // 3 keys of 78 + 2 gaps of 26 = 286 wide; ~600 tall in total.
            return Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(
                  width: 320,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.lock_rounded, color: Colors.white, size: 26),
                        const SizedBox(height: 14),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w400,
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(height: 6),
                        SizedBox(
                          height: 20,
                          child: Text(
                            subtitle,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _error != null ? const Color(0xFFFF8A80) : Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        AnimatedBuilder(
                          animation: _shake,
                          builder: (context, child) {
                            final t = _shake.value;
                            final dx = t == 0 ? 0.0 : 14 * (1 - t) * math.sin(t * math.pi * 6);
                            return Transform.translate(offset: Offset(dx, 0), child: child);
                          },
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              for (var i = 0; i < _length; i++)
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 120),
                                  width: 13,
                                  height: 13,
                                  margin: const EdgeInsets.symmetric(horizontal: 11),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: i < _pin.length ? Colors.white : Colors.transparent,
                                    border: Border.all(color: Colors.white, width: 1.3),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 40),
                        for (final row in const [
                          [['1', ''], ['2', 'ABC'], ['3', 'DEF']],
                          [['4', 'GHI'], ['5', 'JKL'], ['6', 'MNO']],
                          [['7', 'PQRS'], ['8', 'TUV'], ['9', 'WXYZ']],
                        ]) ...[
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              for (var c = 0; c < 3; c++) ...[
                                if (c > 0) const SizedBox(width: _PinKey.gap),
                                _PinKey(
                                  digit: row[c][0],
                                  letters: row[c][1],
                                  onTap: () => _press(row[c][0]),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 18),
                        ],
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Left slot: no biometric support in this app, so empty.
                            const SizedBox(width: _PinKey.size, height: _PinKey.size),
                            const SizedBox(width: _PinKey.gap),
                            _PinKey(digit: '0', letters: '', onTap: () => _press('0')),
                            const SizedBox(width: _PinKey.gap),
                            SizedBox(
                              width: _PinKey.size,
                              height: _PinKey.size,
                              child: TextButton(
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  shape: const CircleBorder(),
                                  padding: EdgeInsets.zero,
                                ),
                                onPressed: _pin.isEmpty ? _cancel : _backspace,
                                child: Text(
                                  _pin.isEmpty ? 'Cancel' : 'Delete',
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w400),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// iPhone-style passcode key: translucent circle, big light digit, letters.
class _PinKey extends StatefulWidget {
  const _PinKey({required this.digit, required this.letters, required this.onTap});

  static const size = 78.0;
  static const gap = 26.0;

  final String digit;
  final String letters;
  final VoidCallback onTap;

  @override
  State<_PinKey> createState() => _PinKeyState();
}

class _PinKeyState extends State<_PinKey> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) {
        setState(() => _down = false);
        widget.onTap();
      },
      child: AnimatedContainer(
        duration: Duration(milliseconds: _down ? 40 : 260),
        curve: Curves.easeOut,
        width: _PinKey.size,
        height: _PinKey.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: _down ? 0.45 : 0.17),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              widget.digit,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 34,
                fontWeight: FontWeight.w300,
                height: 1.05,
              ),
            ),
            if (widget.letters.isNotEmpty)
              Text(
                widget.letters,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 2,
                  height: 1.2,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Future<bool> ensureVaultUnlocked(BuildContext context, WidgetRef ref) async {
  if (ref.read(vaultUnlockedProvider)) return true;
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF0A1118),
    showDragHandle: false,
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: math.min(MediaQuery.sizeOf(context).height * 0.9, 720),
        child: VaultLockPane(
          onUnlocked: () => Navigator.pop(context, true),
        ),
      ),
    ),
  );
  return ok == true || ref.read(vaultUnlockedProvider);
}
