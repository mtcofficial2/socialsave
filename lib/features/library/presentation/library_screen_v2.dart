import 'dart:math' as math;
import 'package:social_save/core/config/build_flags.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

import 'package:file_selector/file_selector.dart' show getDirectoryPath;

import 'package:flutter/material.dart';
import 'package:social_save/shared/widgets/liquid_glass.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/platform/desktop_support.dart';
import 'package:social_save/core/platform/phone_body.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/downloads/presentation/providers/downloads_controller.dart';
import 'package:social_save/features/home/presentation/widgets/link_offer.dart';
import 'package:social_save/features/library/library_sync.dart';
import 'package:social_save/features/library/bundle_ui.dart';
import 'package:social_save/features/library/device_media.dart';
import 'package:social_save/features/library/library_catalog.dart';
import 'package:social_save/features/library/nearby_ui.dart';
import 'package:social_save/features/library/phone_handoff.dart';
import 'package:social_save/features/library/session_ui.dart';
import 'package:social_save/features/library/share_session.dart';
import 'package:social_save/features/library/presentation/library_look.dart';
import 'package:social_save/features/library/presentation/library_screen.dart'
    show
        LibraryScreen,
        VaultLockPane,
        ensureVaultUnlocked,
        vaultServiceProvider,
        vaultUnlockedProvider;
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';
import 'package:social_save/features/library/summarize_sheet.dart';
import 'package:social_save/features/library/tiktok_ready.dart';
import 'package:social_save/features/player/presentation/screens/in_app_player_screen.dart';
import 'package:social_save/features/library/vault_service.dart';
import 'package:social_save/shared/routing/app_router.dart'
    show debugOpenVault, debugOpenMenu, debugDockFirst;
import 'package:social_save/shared/widgets/skeleton.dart';
import 'package:social_save/features/player/open_player.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/widgets/local_video_thumb.dart';

double _libraryGutter(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (width >= 1100) return 32;
  if (width >= 840) return 24;
  return 20;
}

/// Picks the Library live: the new one, or the old one when Settings >
/// Appearance > "Classic library" is on.
class LibraryGate extends ConsumerWidget {
  const LibraryGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final classic = ref.watch(settingsControllerProvider.select((s) => s.classicLibrary));
    return classic ? const LibraryScreen() : const LibraryScreenV2();
  }
}

class LibraryScreenV2 extends ConsumerStatefulWidget {
  const LibraryScreenV2({super.key});

  @override
  ConsumerState<LibraryScreenV2> createState() => _LibraryScreenV2State();
}
class _LibraryScreenV2State extends ConsumerState<LibraryScreenV2>
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
  final TextEditingController _search = TextEditingController();

  /// Library order (1.0.37): newest, oldest, name, size, length. Saved.
  String _sort = 'newest';
  static const _sortKey = 'library.sort.v1';

  /// Saved resume spots, keyed like the player's resume_position keys.
  Map<String, int> _resume = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _search.addListener(_onSearch);
    _reload();
    unawaited(_loadSort());
  }

  Future<void> _loadSort() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_sortKey);
    if (!mounted || saved == null || saved == _sort) return;
    setState(() {
      _sort = saved;
      _device = _sorted(_device);
    });
  }

  Future<void> _setSort(String value) async {
    setState(() {
      _sort = value;
      _device = _sorted(_device);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sortKey, value);
  }

  List<DeviceVideo> _sorted(List<DeviceVideo> input) {
    final list = List<DeviceVideo>.of(input);
    int byName(DeviceVideo a, DeviceVideo b) =>
        a.title.toLowerCase().compareTo(b.title.toLowerCase());
    switch (_sort) {
      case 'oldest':
        list.sort((a, b) => a.addedAt.compareTo(b.addedAt));
      case 'name':
        list.sort(byName);
      case 'size':
        list.sort((a, b) => b.size.compareTo(a.size));
      case 'length':
        list.sort((a, b) => b.durationMs.compareTo(a.durationMs));
      default:
        list.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    }
    return list;
  }

  /// Reads the player's saved positions so cards can show how far you got.
  Future<void> _loadResume() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = <String, int>{};
      for (final key in prefs.getKeys()) {
        if (!key.startsWith('player.pos.v2.')) continue;
        final v = prefs.get(key);
        if (v is int) map[key] = v;
      }
      if (mounted) setState(() => _resume = map);
    } catch (_) {}
  }

  /// 0..1 watched fraction for [video], or null when there is no resume spot.
  double? _progressOf(DeviceVideo video) {
    if (video.durationMs <= 0 || _resume.isEmpty) return null;
    final ms = _resume['player.pos.v2.file.${video.path ?? ''}'] ??
        _resume['player.pos.v2.device.${video.id}'];
    if (ms == null || ms < 1000) return null;
    return (ms / video.durationMs).clamp(0.02, 1.0).toDouble();
  }

  void _onSearch() {
    if (!mounted || _search.text == _query) return;
    setState(() => _query = _search.text);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanSub?.cancel();
    _search.removeListener(_onSearch);
    _search.dispose();
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
    unawaited(_loadResume());
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
          videos.isGranted ||
          videos.isLimited ||
          storage.isGranted ||
          storage.isLimited;
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
        _device = _sorted(device);
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
        _device = _sorted(cached);
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
          _device = _sorted(batch);
          _loading = false;
        });
        // Screenshot hook (`--open-menu`): open the first video's menu once.
        if (debugOpenMenu && batch.isNotEmpty) {
          debugOpenMenu = false;
          Future<void>.delayed(const Duration(seconds: 2), () {
            if (mounted && _device.isNotEmpty) _deviceActions(_device.first);
          });
        }
        // Test hook (`--dock-first`): play the first video beside the list.
        if (debugDockFirst && batch.isNotEmpty) {
          debugDockFirst = false;
          Future<void>.delayed(const Duration(seconds: 2), () {
            if (mounted && _device.isNotEmpty) _playDevice(_device.first);
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
                  subtitle: Text(
                    'SocialSave looks for videos in these folders and the folders inside them.',
                  ),
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
                      final picked = await getDirectoryPath(
                        confirmButtonText: 'Add folder',
                      );
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
    // Back from the player: refresh the watched bars.
    if (mounted) unawaited(_loadResume());
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
    await ref
        .read(vaultServiceProvider)
        .importFile(sourcePath: path, title: video.title);
    if (move) {
      await DeviceMediaService().deletePublic(video);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(move ? 'Moved to vault' : 'Copied to vault')),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.delete): () {
          if (_tab != 0 || _selected.isEmpty) return;
          _deleteVideos(
            _device.where((v) => _selected.contains(v.id)).toList(),
          );
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
    final catalog = ref.watch(libraryCatalogProvider);
    final unlocked = ref.watch(vaultUnlockedProvider);
    final visibleCount = _tab == 0
        ? _device.where(_matchesVideo).length
        : _vault.where(_matchesVault).length;
    final selecting = _tab == 0 && (_selectMode || _selected.isNotEmpty);
    final vaultLocked = _tab == 1 && !unlocked;
    final look = LibraryPalette.of(context);
    return Scaffold(
      backgroundColor: look.bg,
      body: SafeArea(bottom: false, 
        child: Column(
          children: [
            _Rise(
              index: 0,
              child: Padding(
                padding: EdgeInsets.fromLTRB(gutter, 14, math.max(8, gutter - 8), 0),
                child: selecting ? _selectHeader() : _titleHeader(visibleCount),
              ),
            ),
            _Rise(
              index: 1,
              child: Padding(
                padding: EdgeInsets.fromLTRB(gutter, 14, gutter, 0),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 640;
                    final sourceLabel = DesktopSupport.isWindows ? 'This PC' : 'This phone';
                    final sourceIcon = DesktopSupport.isWindows
                        ? Icons.computer_rounded
                        : Icons.smartphone_rounded;
                    final switcher = _sourceSwitch(sourceIcon, sourceLabel);
                    if (!wide || _tab != 0) return switcher;
                    final switchWidth = (constraints.maxWidth * 0.42).clamp(300.0, 440.0);
                    return Row(
                      children: [
                        SizedBox(width: switchWidth, child: switcher),
                        const SizedBox(width: 16),
                        Expanded(child: _searchField()),
                      ],
                    );
                  },
                ),
              ),
            ),
            if (_tab == 0) ...[
              LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth >= 640) return const SizedBox(height: 4);
                  return _Rise(
                    index: 2,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 0),
                      child: _searchField(),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              _Rise(
                index: 3,
                child: SizedBox(
                  height: 44,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.symmetric(horizontal: gutter),
                    children: [
                      for (final name in const ['All', 'YouTube', 'TikTok', 'Instagram', 'Facebook', 'X'])
                        _filterPill(
                          label: name,
                          selected: _platform == name,
                          onTap: () => setState(() => _platform = name),
                        ),
                      _filterPill(
                        label: 'Favorites',
                        selected: _favoritesOnly,
                        icon: Icons.favorite_rounded,
                        iconColor: look.danger,
                        onTap: () => setState(() => _favoritesOnly = !_favoritesOnly),
                      ),
                      for (final name in catalog.collectionNames)
                        _filterPill(
                          label: '#$name',
                          selected: _collection == name,
                          onTap: () => setState(() {
                            _collection = _collection == name ? null : name;
                          }),
                        ),
                      _filterPill(
                        label: 'New collection',
                        icon: Icons.add_rounded,
                        dashed: true,
                        onTap: _createCollection,
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_tab == 1 && unlocked)
              Padding(
                padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 0),
                child: _vaultBanner(),
              ),
            if (DesktopSupport.isWindows && _scanning && _tab == 0)
              Padding(
                padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 0),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: look.accent),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Looking for videos on this PC. ${_device.length} found',
                      style: TextStyle(color: look.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final twoPane = MediaQuery.sizeOf(context).width >= 900;
                  final list = _libraryList(catalog);
                  if (!twoPane) return list;
                  final docked = _docked;
                  return Row(
                    children: [
                      Expanded(child: list),
                      const VerticalDivider(width: 1),
                      SizedBox(
                        width: (constraints.maxWidth * 0.48).clamp(320.0, 640.0),
                        child: docked == null
                            ? const _V2Empty(
                                icon: Icons.play_circle_outline_rounded,
                                title: 'Nothing playing',
                                message: 'Choose a video to play it beside the library.',
                              )
                            : InAppPlayerScreen(
                                key: ValueKey('${docked.filePath ?? docked.title}-${docked.queueIndex}'),
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

  Widget _titleHeader(int count) {
    final look = LibraryPalette.of(context);
    return SizedBox(
      height: 64,
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    'Library',
                    style: TextStyle(color: look.ink, fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -1, height: 1.1),
                  ),
                ),
                Text(
                  _tab == 0 ? '$count videos' : '$count private items',
                  style: TextStyle(color: look.muted, fontSize: 13, height: 1.3),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            key: const ValueKey('library-menu'),
            tooltip: 'Library options',
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: Icon(Icons.more_horiz_rounded, color: look.muted, size: 26),
            onSelected: (v) {
              HapticFeedback.selectionClick();
              if (v.startsWith('sort:')) {
                unawaited(_setSort(v.substring(5)));
              } else if (v == 'refresh') {
                unawaited(_reload(rescan: true));
              } else if (v == 'select') {
                setState(() => _selectMode = true);
              } else if (v == 'received') {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const ReceivedScreen()),
                );
              } else if (v == 'folders') {
                unawaited(_manageWindowsFolders());
              }
            },
            itemBuilder: (context) => [
              if (_tab == 0) ...[
                for (final (value, label) in const [
                  ('newest', 'Newest first'),
                  ('oldest', 'Oldest first'),
                  ('name', 'Name (A to Z)'),
                  ('size', 'Largest first'),
                  ('length', 'Longest first'),
                ])
                  CheckedPopupMenuItem<String>(
                    value: 'sort:$value',
                    checked: _sort == value,
                    child: Text(label),
                  ),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'select', child: Text('Select videos')),
              ],
              const PopupMenuItem(value: 'refresh', child: Text('Refresh')),
              const PopupMenuItem(value: 'received', child: Text('Received files')),
              if (DesktopSupport.isWindows)
                const PopupMenuItem(value: 'folders', child: Text('Video folders')),
            ],
          ),
        ],
      ),
    );
  }
  Widget _selectHeader() {
    final look = LibraryPalette.of(context);
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: look.card,
        borderRadius: BorderRadius.circular(LibraryPalette.radius),
        border: Border.all(color: look.border),
      ),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('library-select'),
            tooltip: 'Cancel',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() {
              _selected.clear();
              _selectMode = false;
            }),
            icon: Icon(Icons.close_rounded, color: look.ink),
          ),
          Text(
            '${_selected.length} selected',
            style: TextStyle(
              color: look.ink,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => setState(
              () => _selected.addAll(
                _device.where(_matchesVideo).map((v) => v.id),
              ),
            ),
            style: TextButton.styleFrom(
              foregroundColor: look.accent,
              visualDensity: VisualDensity.compact,
            ),
            child: const Text(
              'Select all',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
            ),
          ),
          TextButton.icon(
            onPressed: () => _deleteVideos(
              _device.where((v) => _selected.contains(v.id)).toList(),
            ),
            style: TextButton.styleFrom(
              foregroundColor: look.danger,
              backgroundColor: look.dangerDim,
              visualDensity: VisualDensity.compact,
            ),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text(
              'Delete',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _sourceSwitch(IconData sourceIcon, String sourceLabel) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 52,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: GlassChoiceShell(
        index: _tab,
        count: 2,
        child: Row(
          children: [
            Expanded(child: _sourceTab(0, sourceIcon, sourceLabel)),
            Expanded(child: _sourceTab(1, Icons.lock_rounded, 'Vault')),
          ],
        ),
      ),
    );
  }

  Widget _sourceTab(int value, IconData icon, String label) {
    final scheme = Theme.of(context).colorScheme;
    final glass = LiquidGlassScope.of(context);
    final on = _tab == value;
    final fg = glass
        ? (on ? scheme.primary : scheme.onSurfaceVariant)
        : (on ? scheme.onPrimaryContainer : scheme.onSurfaceVariant);
    return Semantics(
      button: true,
      selected: on,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          _selectTab(value);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: !glass && on ? scheme.primaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 8),
              Text(label, style: TextStyle(color: fg, fontWeight: on ? FontWeight.w800 : FontWeight.w600, fontSize: 14)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchField() {
    final look = LibraryPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      controller: _search,
      style: TextStyle(color: look.ink, fontSize: 15),
      cursorColor: look.accent,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Search your library',
        hintStyle: TextStyle(color: look.muted, fontSize: 15),
        prefixIcon: Icon(Icons.search_rounded, color: look.muted, size: 22),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _search.clear,
                icon: Icon(Icons.cancel_rounded, color: look.muted, size: 20),
              ),
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(vertical: 15),
        border: _searchBorder(Colors.transparent),
        enabledBorder: _searchBorder(Colors.transparent),
        focusedBorder: _searchBorder(look.accent.withValues(alpha: 0.7)),
      ),
    );
  }

  OutlineInputBorder _searchBorder(Color color) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(26),
      borderSide: BorderSide(color: color),
    );
  }

  Widget _filterPill({
    required String label,
    required VoidCallback onTap,
    bool selected = false,
    bool dashed = false,
    IconData? icon,
    Color? iconColor,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected
        ? scheme.onPrimaryContainer
        : (dashed ? scheme.primary : scheme.onSurface);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        excludeSemantics: true,
        child: Material(
          color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
          shape: StadiumBorder(
            side: BorderSide(
              color: dashed
                  ? scheme.primary.withValues(alpha: 0.5)
                  : (selected ? Colors.transparent : scheme.outlineVariant.withValues(alpha: 0.5)),
            ),
          ),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: () {
              HapticFeedback.selectionClick();
              onTap();
            },
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 16, color: iconColor ?? fg),
                      const SizedBox(width: 6),
                    ],
                    Text(label, style: TextStyle(color: fg, fontSize: 13.5, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
  Widget _vaultBanner() {
    final look = LibraryPalette.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: BoxDecoration(
        color: look.card,
        borderRadius: BorderRadius.circular(LibraryPalette.radius),
        border: Border.all(color: look.border),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_rounded, color: look.accent, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Private PIN Vault · AES-256',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: look.ink,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: look.ink,
              backgroundColor: look.raised,
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 32),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: look.border),
              ),
            ),
            onPressed: () =>
                ref.read(vaultUnlockedProvider.notifier).state = false,
            icon: const Icon(Icons.lock_clock_rounded, size: 16),
            label: const Text(
              'Lock',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _libraryList(LibraryCatalog catalog) {
    // The PIN pad does not need the video scan, so it can fill the page at once.
    if (_tab == 1 && !ref.watch(vaultUnlockedProvider)) {
      return VaultLockPane(
        onUnlocked: () => _reload(),
        onCancel: () => setState(() => _tab = 0),
      );
    }
    if (_loading) return const SkeletonGrid();
    if (_error != null) {
      return _V2Empty(
        icon: Icons.no_photography_outlined,
        title: 'Unable to read media files',
        message: _error!,
        danger: true,
        action: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: LibraryPalette.of(context).accent,
            foregroundColor: LibraryPalette.of(context).onAccent,
          ),
          onPressed: () => _reload(rescan: true),
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Try again'),
        ),
      );
    }
    if (_tab == 0) {
      final filtered =
          _query.trim().isNotEmpty ||
          _favoritesOnly ||
          _collection != null ||
          _platform != 'All';
      final records = ref.watch(downloadsControllerProvider).valueOrNull ?? const <DownloadRecord>[];
      final later = filtered ? const <WatchLaterItem>[] : catalog.later;
      final sync = filtered
          ? const <DownloadRecord>[]
          : [
              for (final record in records)
                if (record.id.startsWith(LibrarySync.idPrefix) && record.sourceUrl.trim().isNotEmpty) record,
            ];
      final list = _DeviceList(
        selected: _selected,
        selecting: _selectMode || _selected.isNotEmpty,
        favorites: catalog.favorites,
        onDelete: (video) => _deleteVideos([video]),
        onToggle: _toggleSelect,
        onFavorite: (video) => ref
            .read(libraryCatalogProvider.notifier)
            .toggleFavorite('device:${video.id}'),
        videos: _device.where(_matchesVideo).toList(),
        filtered: filtered,
        hideEmpty: later.isNotEmpty || sync.isNotEmpty,
        onPlay: _playDevice,
        progressOf: _progressOf,
        onRefresh: () => _reload(rescan: true),
        onVault: (video) => _confirmVault(video),
        onActions: _deviceActions,
        onSend: _sendDevice,
      );
      if (later.isEmpty && sync.isEmpty) return list;
      return Column(
        children: [
          _SavedElsewhere(
            later: later,
            sync: sync,
            onOpen: (url) {
              offerLink(url);
            },
            onRemoveLater: (url) {
              ref.read(libraryCatalogProvider.notifier).removeLater(url);
            },
          ),
          Expanded(child: list),
        ],
      );
    }
    return _VaultGate(
      items: _vault.where(_matchesVault).toList(),
      paths: _vaultPaths,
      onPlay: _playVault,
      onActions: _vaultItemActions,
      onToLibrary: (item) => _restoreVault(item, copy: false),
      onDelete: _deleteVaultItem,
      onReload: _reload,
    );
  }

  bool _matchesVideo(DeviceVideo video) {
    if (!_matchesText('${video.title} ${video.path ?? ''}')) return false;
    final catalog = ref.read(libraryCatalogProvider);
    final key = 'device:${video.id}';
    if (_favoritesOnly && !catalog.isFavorite(key)) return false;
    final collection = _collection;
    if (collection != null && !catalog.inCollection(collection, key))
      return false;
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

  Future<void> _restoreVault(VaultItem item, {required bool copy}) async {
    try {
      await ref.read(vaultServiceProvider).restoreToGallery(item);
      if (!copy) {
        await ref.read(vaultServiceProvider).delete(item);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            copy
                ? 'Copied to Library. The vault copy is still locked.'
                : 'Moved to Library. It is no longer in the vault.',
          ),
        ),
      );
      setState(() => _tab = 0);
      await _reload();
    } on StateError catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not move this video back to Library.'),
        ),
      );
    }
  }

  Future<void> _vaultItemActions(VaultItem item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Take out of vault'),
              subtitle: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
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
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('Delete forever'),
              subtitle: const Text(
                'Remove it from the vault without putting it back in Gallery',
              ),
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
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
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
    await _restoreVault(item, copy: action == 'copy');
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Removed from vault.')));
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
                    title: Text(
                      videos[i].title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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
                subtitle: Text(
                  'The other phone or PC can watch it or save a copy.',
                ),
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
                    title: Text(
                      videos[i].title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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
          title: Text(
            video.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            _durationLabel((video.durationMs / 1000).round(), video.size),
          ),
          trailing: IconButton(
            tooltip: 'Delete',
            icon: Icon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, 'delete'),
          ),
        ),
        if (ShareSession.active)
          ListTile(
            key: const ValueKey('menu-session-send'),
            leading: Icon(Icons.send_rounded, color: Theme.of(context).colorScheme.primary),
            title: Text('Send to ${ShareSession.peer.value!.name}',
                style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700)),
            subtitle: const Text('Connected · goes straight there'),
            onTap: () => Navigator.pop(context, 'session'),
          ),
        ListTile(
          leading: const Icon(Icons.play_arrow_rounded),
          title: const Text('Play'),
          onTap: () => Navigator.pop(context, 'play'),
        ),
        ListTile(
          key: const ValueKey('menu-delete'),
          leading: Icon(
            Icons.delete_outline,
            color: Theme.of(context).colorScheme.error,
          ),
          title: Text(
            DesktopSupport.isWindows
                ? 'Delete (Recycle Bin)'
                : 'Delete from phone',
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontWeight: FontWeight.w600,
            ),
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
        if (!DesktopSupport.isWindows)
          ListTile(
            leading: const Icon(Icons.movie_filter_outlined),
            title: const Text('Prepare for another app'),
            subtitle: const Text('TikTok, Reels, Shorts, or X. The saved file stays until you choose.'),
            onTap: () => Navigator.pop(context, 'tiktok'),
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
          subtitle: const Text(
            'Phone or PC on this Wi-Fi: QR or 6-letter code. Watch or save.',
          ),
          onTap: () => Navigator.pop(context, 'handoff'),
        ),
        ListTile(
          leading: const Icon(Icons.phonelink_rounded),
          title: const Text('Hold phones together'),
          subtitle: const Text('Quick Share between the two phones'),
          onTap: () => Navigator.pop(context, 'near'),
        ),
        ListTile(
          leading: const Icon(Icons.music_note_rounded),
          title: const Text('Keep the sound'),
          subtitle: const Text('Save the whole audio in Music, titled with the creator'),
          onTap: () => Navigator.pop(context, 'keep'),
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
          title: const Text('Move to collection'),
          onTap: () => Navigator.pop(context, 'collection'),
        ),
        ListTile(
          leading: const Icon(Icons.notes_outlined),
          title: const Text('Note'),
          onTap: () => Navigator.pop(context, 'note'),
        ),
        // Summaries use the hosted API's AI key; the desktop app is offline-only.
        if (!kLocalEngine)
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
    if (action == 'tiktok') {
      final path = await DeviceMediaService().resolvePlayablePath(video);
      if (!mounted) return;
      if (path == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That video is not on this phone.')),
        );
        return;
      }
      final refresh = await offerTiktokReady(context, path: path, title: video.title);
      if (refresh && mounted) await _reload();
      return;
    }
    if (action == 'share' ||
        action == 'near' ||
        action == 'tv' ||
        action == 'handoff' ||
        action == 'session' ||
        action == 'sound' ||
        action == 'keep') {
      final path = await DeviceMediaService().resolvePlayablePath(video);
      if (path == null || !mounted) return;
      if (action == 'session') {
        sendToSessionPeer(context, File(path));
        return;
      }
      if (action == 'share' || action == 'near') {
        await Share.shareXFiles([XFile(path)], text: video.title);
        return;
      }
      if (action == 'tv') {
        final ok = await PhoneBody.playOnTv(path: path, title: video.title);
        if (!mounted) return;
        if (!ok) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No TV app on this phone could open the video.'),
            ),
          );
        }
        return;
      }
      if (action == 'handoff') {
        await showSendToPhone(context, File(path), video.title);
        return;
      }
      if (action == 'keep') {
        final record = await _recordForPath(path);
        final author = record?.author?.trim();
        await showKeepSound(
          context,
          path,
          title: (author != null && author.isNotEmpty) ? author : video.title,
        );
        return;
      }
      await showSoundClip(context, path);
      return;
    }
    if (action == 'favorite') {
      await ref
          .read(libraryCatalogProvider.notifier)
          .toggleFavorite('device:${video.id}');
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
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
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
  Future<String?> _showItemMenu({
    required List<Widget> Function(BuildContext) builder,
  }) {
    final size = MediaQuery.sizeOf(context);
    if (DesktopSupport.isWindows || size.width >= 700) {
      return showDialog<String>(
        context: context,
        builder: (context) => Dialog(
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 440,
              maxHeight: size.height * 0.85,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: builder(context),
              ),
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: builder(context),
          ),
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
    final what = videos.length == 1
        ? '“${videos.first.title}”'
        : '${videos.length} videos';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          Icons.delete_outline,
          color: Theme.of(context).colorScheme.error,
        ),
        title: Text('Delete $what?'),
        content: Text(
          DesktopSupport.isWindows
              ? 'This removes the file${videos.length == 1 ? '' : 's'} from your device (moved to the Recycle Bin).'
              : 'This removes the file${videos.length == 1 ? '' : 's'} from your device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
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
      final gonePaths = [
        for (final v in videos)
          if (v.path != null && !File(v.path!).existsSync()) v.path!,
      ];
      final names = {
        for (final p in gonePaths)
          p.split(Platform.pathSeparator).last.split('/').last,
      };
      final paths = gonePaths.toSet();
      for (final record in await repo.getAll()) {
        final local = record.localPath;
        if (local == null || local.isEmpty) continue;
        final name = local.split(Platform.pathSeparator).last.split('/').last;
        final ownCopy =
            local.contains('/Android/data/') && names.contains(name);
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          deleted >= videos.length
              ? 'Deleted ${videos.length == 1 ? '1 video' : '${videos.length} videos'}${DesktopSupport.isWindows ? ' (moved to the Recycle Bin)' : ''}.'
              : deleted == 0
              ? 'Nothing was deleted.'
              : 'Deleted $deleted of ${videos.length}. The rest were kept.',
        ),
      ),
    );
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
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
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
              subtitle: Text(
                'Vault files stay inside SocialSave and need your PIN.',
              ),
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
    await ref
        .read(libraryCatalogProvider.notifier)
        .moveToCollection(name, 'device:${video.id}');
  }

  Future<void> _editNote(String key) async {
    final current = ref.read(libraryCatalogProvider).notes[key] ?? '';
    final note = await _askText(
      'Note',
      'A note for this video',
      initial: current,
    );
    if (note == null) return;
    await ref.read(libraryCatalogProvider.notifier).setNote(key, note);
  }

  Future<String?> _askText(
    String title,
    String label, {
    String initial = '',
  }) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
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
    required this.favorites,
    required this.onDelete,
    required this.onToggle,
    required this.onFavorite,
    required this.videos,
    required this.filtered,
    this.hideEmpty = false,
    required this.onPlay,
    required this.onVault,
    required this.onActions,
    required this.onSend,
    this.progressOf,
    this.onRefresh,
  });

  final double? Function(DeviceVideo video)? progressOf;
  final Future<void> Function()? onRefresh;
  final ValueChanged<DeviceVideo> onSend;
  final Set<String> selected;
  final bool selecting;
  final Set<String> favorites;
  final ValueChanged<DeviceVideo> onDelete;
  final ValueChanged<DeviceVideo> onToggle;
  final ValueChanged<DeviceVideo> onFavorite;
  final List<DeviceVideo> videos;
  final bool filtered;
  final bool hideEmpty;
  final ValueChanged<DeviceVideo> onPlay;
  final ValueChanged<DeviceVideo> onVault;
  final ValueChanged<DeviceVideo> onActions;

  @override
  Widget build(BuildContext context) {
    if (videos.isEmpty) {
      if (hideEmpty) return const SizedBox.shrink();
      if (filtered) {
        return const _V2Empty(
          icon: Icons.search_off_rounded,
          title: 'No videos match',
          message: 'Try another title, platform, or collection.',
        );
      }
      if (DesktopSupport.isWindows) {
        return const _V2Empty(
          icon: Icons.video_library_outlined,
          title: 'No videos found on this PC',
          message:
              'Add a folder with the folder button above, or download a video, then refresh.',
        );
      }
      return const _V2Empty(
        icon: Icons.play_circle_rounded,
        title: 'Your library is empty',
        message:
            'Download your favorite reels, shorts, and TikTok videos to watch offline anytime.',
      );
    }
    final grid = GridView.builder(
      // Always scrollable so pull-to-refresh works with only a few videos.
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        _libraryGutter(context),
        4,
        _libraryGutter(context),
        130,
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 240,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: 0.74,
      ),
      itemCount: videos.length,
      itemBuilder: (context, index) {
        final video = videos[index];
        final seconds = (video.durationMs / 1000).round();
        final when = libraryWhen(libraryAdded(video.addedAt));
        final folder = DesktopSupport.isWindows ? _folderName(video) : '';
        return _Rise(seenKey: 'd${video.id}', index: index, child: _VideoCard(
          cacheKey: 'device-${video.id}',
          id: video.id,
          path: video.path,
          uri: video.uri,
          title: video.title,
          caption: [
            librarySize(video.size),
            if (when.isNotEmpty) when,
            if (folder.isNotEmpty) folder,
          ].join(' • '),
          durationLabel: seconds == 0 ? null : libraryClock(seconds),
          platform: libraryPlatformBadge(
            '${video.title} ${video.path ?? ''} ${video.folder ?? ''}',
          ),
          favorite: favorites.contains('device:${video.id}'),
          onFavorite: () => onFavorite(video),
          selected: selected.contains(video.id),
          selecting: selecting,
          onTap: () => selecting ? onToggle(video) : onPlay(video),
          onLongPress: () => onToggle(video),
          heroTag: 'library-${video.id}',
          onSend: () => onSend(video),
          onVault: () => onVault(video),
          onDelete: () => onDelete(video),
          onMore: () => onActions(video),
          deleteKey: ValueKey('card-delete-${video.id}'),
          progress: progressOf?.call(video),
        ));
      },
    );
    final refresh = onRefresh;
    if (refresh == null) return grid;
    return RefreshIndicator(onRefresh: refresh, child: grid);
  }
}

class _SavedElsewhere extends StatelessWidget {
  const _SavedElsewhere({
    required this.later,
    required this.sync,
    required this.onOpen,
    required this.onRemoveLater,
  });

  final List<WatchLaterItem> later;
  final List<DownloadRecord> sync;
  final ValueChanged<String> onOpen;
  final ValueChanged<String> onRemoveLater;

  @override
  Widget build(BuildContext context) {
    final look = LibraryPalette.of(context);
    final gutter = _libraryGutter(context);
    final children = <Widget>[];
    if (later.isNotEmpty) {
      children.add(_heading(look, 'Watch later'));
      for (final item in later) {
        children.add(_line(
          look,
          title: item.title,
          caption: 'Nothing downloaded yet',
          onTap: () => onOpen(item.url),
          onClose: () => onRemoveLater(item.url),
        ));
      }
    }
    if (sync.isNotEmpty) {
      children.add(_heading(look, 'On your other device'));
      for (final record in sync.take(12)) {
        children.add(_line(
          look,
          title: record.title,
          caption: 'Tap to download it here',
          onTap: () => onOpen(record.sourceUrl),
        ));
      }
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 240),
      child: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 8),
        children: children,
      ),
    );
  }

  Widget _heading(LibraryPalette look, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 4),
      child: Text(
        text,
        style: TextStyle(color: look.ink, fontSize: 13, fontWeight: FontWeight.w800),
      ),
    );
  }

  Widget _line(
    LibraryPalette look, {
    required String title,
    required String caption,
    required VoidCallback onTap,
    VoidCallback? onClose,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: look.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: look.border),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: look.ink, fontWeight: FontWeight.w700),
                        ),
                        Text(caption, style: TextStyle(color: look.muted, fontSize: 12)),
                      ],
                    ),
                  ),
                  if (onClose != null)
                    IconButton(
                      tooltip: 'Remove',
                      onPressed: onClose,
                      icon: Icon(Icons.close_rounded, color: look.muted, size: 18),
                    )
                  else
                    Icon(Icons.download_rounded, color: look.accent, size: 18),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _folderName(DeviceVideo video) {
  final folder =
      video.folder ?? (video.path == null ? '' : File(video.path!).parent.path);
  if (folder.isEmpty) return '';
  return folder.split(Platform.pathSeparator).last;
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
    this.heroTag,
    this.platform,
    this.favorite = false,
    this.progress,
    this.onFavorite,
    this.vault = false,
    this.missing = false,
    this.selected = false,
    this.selecting = false,
    this.onSend,
    this.onVault,
    this.onDelete,
    this.onMore,
    this.onToLibrary,
    this.deleteKey,
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
  final String? heroTag;
  final String? platform;
  final bool favorite;

  /// How much was watched (0..1); a thin bar along the thumbnail's bottom.
  final double? progress;
  final VoidCallback? onFavorite;
  final bool vault;
  final bool missing;
  final bool selected;
  final bool selecting;
  final VoidCallback? onSend;
  final VoidCallback? onVault;
  final VoidCallback? onDelete;
  final VoidCallback? onMore;
  final VoidCallback? onToLibrary;
  final Key? deleteKey;

  @override
  Widget build(BuildContext context) {
    final look = LibraryPalette.of(context);
    final card = Material(
      color: look.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(
          color: missing
              ? Colors.transparent
              : selected
                  ? look.accent
                  : look.border.withValues(alpha: 0.45),
          width: selected ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        onLongPress: onLongPress == null
            ? null
            : () {
                HapticFeedback.heavyImpact();
                onLongPress!();
              },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: missing
                      ? _missingThumb(look)
                      : progress == null
                          ? _thumb(context)
                          : Stack(
                              fit: StackFit.expand,
                              children: [
                                _thumb(context),
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: LinearProgressIndicator(
                                    value: progress,
                                    minHeight: 3,
                                    color: look.accent,
                                    backgroundColor: Colors.black.withValues(alpha: 0.35),
                                  ),
                                ),
                              ],
                            ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(14, 2, vault || missing ? 12 : 0, vault || missing ? 0 : 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: vault ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: missing ? look.muted : look.ink,
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                      height: 1.25,
                      decoration: missing ? TextDecoration.lineThrough : null,
                      decorationColor: look.muted,
                    ),
                  ),
                  if (caption != null && caption!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        caption!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, height: 1.3, color: look.muted),
                      ),
                    ),
                ],
              ),
                  ),
                  if (!vault && !missing) _cardMenu(look),
                ],
              ),
            ),
            if (missing && onDelete != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: TextButton.icon(
                  key: deleteKey,
                  style: TextButton.styleFrom(
                    foregroundColor: look.danger,
                    backgroundColor: look.dangerDim,
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_forever_rounded, size: 16),
                  label: const Text('Delete record', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                ),
              )
            else if (vault)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                child: _vaultActions(look),
              ),
          ],
        ),
      ),
    );
    final wrapped = Semantics(
      label: '$title${durationLabel != null ? ', $durationLabel' : ''}',
      button: true,
      selected: selected,
      child: card,
    );
    if (!missing) return wrapped;
    return DashedRoundedBorder(
      color: look.danger.withValues(alpha: 0.7),
      child: wrapped,
    );
  }
  Widget _missingThumb(LibraryPalette look) {
    return ColoredBox(
      color: look.raised,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.broken_image_outlined, color: look.danger, size: 28),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'This vault file is missing.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: look.danger,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _thumb(BuildContext context) {
    final look = LibraryPalette.of(context);
    final platformName = platform;
    return Stack(
      fit: StackFit.expand,
      children: [
        HeroMode(
          enabled:
              (ModalRoute.of(context)?.isCurrent ?? true) && heroTag != null,
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
        const DecoratedBox(decoration: BoxDecoration(color: Color(0x1F000000))),
        Center(
          child: Container(
            width: vault ? 36 : 40,
            height: vault ? 36 : 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: vault ? look.accent : const Color(0x99000000),
              border: vault
                  ? null
                  : Border.all(color: Colors.white.withValues(alpha: 0.2)),
            ),
            child: Icon(
              Icons.play_arrow_rounded,
              color: vault ? look.onAccent : Colors.white,
              size: 22,
            ),
          ),
        ),
        if (vault)
          Positioned(
            left: 8,
            top: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: look.accent,
                borderRadius: const BorderRadius.all(Radius.circular(6)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_rounded, color: look.onAccent, size: 10),
                    const SizedBox(width: 2),
                    Text(
                      'VAULT',
                      style: TextStyle(
                        color: look.onAccent,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        else if (platformName != null)
          Positioned(
            left: 8,
            top: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xB3000000),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: libraryPlatformColor(platformName),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      platformName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (!vault && !selecting && onFavorite != null)
          Positioned(
            right: 6,
            top: 6,
            child: Material(
              color: const Color(0x99000000),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onFavorite,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    favorite
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    color: favorite ? look.danger : Colors.white,
                    size: 14,
                  ),
                ),
              ),
            ),
          ),
        if (durationLabel != null)
          Positioned(
            right: 8,
            bottom: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xCC000000),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                child: Text(
                  durationLabel!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        if (selecting)
          Positioned.fill(
            child: ColoredBox(
              color: selected
                  ? look.accent.withValues(alpha: 0.28)
                  : Colors.transparent,
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: selected ? look.accent : const Color(0xCC000000),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.35),
                      ),
                    ),
                    child: selected
                        ? Icon(
                            Icons.check_rounded,
                            color: look.onAccent,
                            size: 16,
                          )
                        : null,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _cardMenu(LibraryPalette look) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      icon: Icon(Icons.more_horiz_rounded, size: 22, color: look.muted),
      onSelected: (v) {
        if (v == 'send') onSend?.call();
        if (v == 'vault') onVault?.call();
        if (v == 'more') onMore?.call();
        if (v == 'delete') onDelete?.call();
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'send', child: Text('Send to another device')),
        const PopupMenuItem(value: 'vault', child: Text('Add to vault')),
        const PopupMenuItem(value: 'more', child: Text('More options')),
        PopupMenuItem(
          key: deleteKey,
          value: 'delete',
          child: Text('Delete', style: TextStyle(color: look.danger)),
        ),
      ],
    );
  }
  Widget _vaultActions(LibraryPalette look) {
    return Row(
      children: [
        Expanded(
          child: TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: look.ink,
              backgroundColor: look.raised,
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: onToLibrary,
            icon: const Icon(Icons.lock_open_rounded, size: 14),
            label: const Text(
              'To Library',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        _actionIcon(Icons.more_vert_rounded, 'Vault options', onMore, look),
      ],
    );
  }

  Widget _actionIcon(
    IconData icon,
    String tooltip,
    VoidCallback? onPressed,
    LibraryPalette look, {
    Color? color,
    Key? buttonKey,
  }) {
    return IconButton(
      key: buttonKey,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      onPressed: onPressed,
      icon: Icon(icon, size: 18, color: color ?? look.muted),
    );
  }
}

class _VaultGate extends ConsumerWidget {
  const _VaultGate({
    required this.items,
    required this.paths,
    required this.onPlay,
    required this.onActions,
    required this.onToLibrary,
    required this.onDelete,
    required this.onReload,
  });

  final List<VaultItem> items;
  final Map<String, String> paths;
  final ValueChanged<VaultItem> onPlay;
  final ValueChanged<VaultItem> onActions;
  final ValueChanged<VaultItem> onToLibrary;
  final ValueChanged<VaultItem> onDelete;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unlocked = ref.watch(vaultUnlockedProvider);
    if (!unlocked) {
      return VaultLockPane(onUnlocked: onReload);
    }
    if (items.isEmpty) {
      return const _V2Empty(
        icon: Icons.lock_outline_rounded,
        title: 'Vault is empty',
        message:
            'From the other tab, use the lock action on a video to hide it behind your PIN.',
      );
    }
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        _libraryGutter(context),
        4,
        _libraryGutter(context),
        130,
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 260,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: 0.8,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final path = paths[item.id];
        final missing =
            path == null || path.isEmpty || !File(path).existsSync();
        final when = libraryWhen(item.addedAt);
        final size = librarySize(item.bytes);
        return _Rise(seenKey: 'v${item.id}', index: index, child: _VideoCard(
          cacheKey: 'vault-${item.id}',
          path: missing ? null : path,
          title: item.title,
          caption: missing
              ? 'Missing from disk'
              : [size, if (when.isNotEmpty) when].join(' • '),
          vault: true,
          missing: missing,
          onTap: () => onPlay(item),
          onLongPress: () => onActions(item),
          onToLibrary: () => onToLibrary(item),
          onMore: () => onActions(item),
          onDelete: () => onDelete(item),
        ));
      },
    );
  }
}

class _LiveDot extends StatelessWidget {
  const _LiveDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: LibraryPalette.of(context).success,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// Fade + slide-up entrance. [seenKey] makes list items animate only once.
class _Rise extends StatefulWidget {
  const _Rise({required this.child, this.index = 0, this.seenKey});
  final Widget child;
  final int index;
  final String? seenKey;
  static final Set<String> _seen = <String>{};

  @override
  State<_Rise> createState() => _RiseState();
}

class _RiseState extends State<_Rise> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  Timer? _t;

  @override
  void initState() {
    super.initState();
    final key = widget.seenKey;
    if (key != null && _Rise._seen.contains(key)) {
      _c.value = 1;
      return;
    }
    if (key != null) _Rise._seen.add(key);
    _t = Timer(Duration(milliseconds: 45 * math.min(widget.index, 10)), () {
      if (mounted) unawaited(_c.forward());
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0, 0.05), end: Offset.zero).animate(curve),
        child: widget.child,
      ),
    );
  }
}

/// Calm empty / error block.
class _V2Empty extends StatelessWidget {
  const _V2Empty({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final look = LibraryPalette.of(context);
    final color = danger ? look.danger : look.accent;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 32, 32, 120),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOutCubic,
            builder: (context, v, child) => Opacity(
              opacity: v,
              child: Transform.translate(offset: Offset(0, 14 * (1 - v)), child: child),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 104,
                  height: 104,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [color.withValues(alpha: 0.30), color.withValues(alpha: 0.06)],
                    ),
                  ),
                  child: Icon(icon, size: 46, color: color),
                ),
                const SizedBox(height: 22),
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.4, color: look.ink),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, height: 1.5, color: look.muted),
                ),
                if (action != null) ...[const SizedBox(height: 20), action!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
