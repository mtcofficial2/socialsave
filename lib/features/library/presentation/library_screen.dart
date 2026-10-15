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
import 'package:social_save/features/library/bundle_ui.dart';
import 'package:social_save/features/library/device_media.dart';
import 'package:social_save/features/library/library_catalog.dart';
import 'package:social_save/features/library/nearby_ui.dart';
import 'package:social_save/features/library/phone_handoff.dart';
import 'package:social_save/features/library/presentation/library_look.dart';
import 'package:social_save/features/library/summarize_sheet.dart';
import 'package:social_save/features/player/presentation/screens/in_app_player_screen.dart';
import 'package:social_save/features/library/vault_service.dart';
import 'package:social_save/shared/routing/app_router.dart'
    show debugOpenVault, debugOpenMenu;
import 'package:social_save/shared/widgets/skeleton.dart';
import 'package:social_save/features/player/open_player.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/shared/models/social_platform.dart';
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
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _search.addListener(_onSearch);
    _reload();
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
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                gutter,
                2,
                math.max(4, gutter - 8),
                0,
              ),
              child: selecting ? _selectHeader() : _titleHeader(visibleCount),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 0),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 640;
                  final sourceLabel = DesktopSupport.isWindows
                      ? 'This PC'
                      : 'This phone';
                  final sourceIcon = DesktopSupport.isWindows
                      ? Icons.computer_rounded
                      : Icons.smartphone_rounded;
                  final switcher = _sourceSwitch(sourceIcon, sourceLabel);
                  if (!wide || _tab != 0) return switcher;
                  final switchWidth = (constraints.maxWidth * 0.42).clamp(
                    300.0,
                    440.0,
                  );
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
            if (_tab == 0) ...[
              LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth >= 640) {
                    return const SizedBox(height: 4);
                  }
                  return Padding(
                    padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 0),
                    child: _searchField(),
                  );
                },
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(horizontal: gutter),
                  children: [
                    for (final name in const [
                      'All',
                      'YouTube',
                      'TikTok',
                      'Instagram',
                      'Facebook',
                      'X',
                    ])
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
                      onTap: () =>
                          setState(() => _favoritesOnly = !_favoritesOnly),
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
            ],
            if (_tab == 1 && unlocked)
              Padding(
                padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 0),
                child: _vaultBanner(),
              ),
            if (!vaultLocked)
              Padding(
                padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 0),
                child: _shareCard(),
              ),
            if (DesktopSupport.isWindows && _scanning && _tab == 0)
              Padding(
                padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 0),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: look.accent,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Looking for videos on this PC… ${_device.length} found',
                      style: TextStyle(color: look.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
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
                        width: (constraints.maxWidth * 0.48).clamp(
                          320.0,
                          640.0,
                        ),
                        child: docked == null
                            ? const LibraryEmpty(
                                icon: Icons.play_circle_outline_rounded,
                                title: 'Nothing playing',
                                message:
                                    'Choose a video to play it beside the library.',
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

  Widget _titleHeader(int count) {
    final look = LibraryPalette.of(context);
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Text(
            'Library',
            style: TextStyle(
              color: look.ink,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: look.accentDim,
              borderRadius: BorderRadius.circular(99),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                color: look.muted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Spacer(),
          if (DesktopSupport.isWindows)
            IconButton(
              tooltip: 'Video folders',
              visualDensity: VisualDensity.compact,
              onPressed: _manageWindowsFolders,
              icon: Icon(Icons.create_new_folder_outlined, color: look.muted),
            ),
          IconButton(
            tooltip: 'Refresh',
            visualDensity: VisualDensity.compact,
            onPressed: () => _reload(rescan: true),
            icon: Icon(Icons.refresh_rounded, color: look.muted),
          ),
          if (_tab == 0)
            TextButton.icon(
              key: const ValueKey('library-select'),
              onPressed: () => setState(() => _selectMode = true),
              style: TextButton.styleFrom(
                foregroundColor: look.accent,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              icon: const Icon(Icons.checklist_rounded, size: 18),
              label: const Text(
                'Select',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
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

  Widget _shareCard() {
    final look = LibraryPalette.of(context);
    return Container(
      key: const ValueKey('library-share'),
      padding: const EdgeInsets.fromLTRB(10, 4, 2, 4),
      decoration: BoxDecoration(
        color: look.card,
        borderRadius: BorderRadius.circular(LibraryPalette.radius),
        border: Border.all(color: look.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.wifi_rounded, color: look.accent, size: 18),
              const SizedBox(width: 6),
              const _LiveDot(),
              const SizedBox(width: 6),
              Text(
                'Share',
                style: TextStyle(
                  color: look.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('nearby-send'),
                  style: FilledButton.styleFrom(
                    backgroundColor: look.accent,
                    foregroundColor: look.onAccent,
                    minimumSize: const Size(0, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _pickLibraryVideoToSend,
                  icon: const Icon(Icons.send_rounded, size: 15),
                  label: const Text(
                    'Send',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('nearby-receive'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: look.ink,
                    backgroundColor: look.raised,
                    minimumSize: const Size(0, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    side: BorderSide(color: look.border),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () async {
                    final saved = await showReceiveFromPhone(context);
                    if (!saved || !mounted) return;
                    await _reload(rescan: DesktopSupport.isWindows);
                  },
                  icon: const Icon(Icons.download_rounded, size: 15),
                  label: const Text(
                    'Receive',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'More sharing options',
                padding: const EdgeInsets.symmetric(horizontal: 4),
                iconSize: 22,
                icon: Icon(Icons.more_horiz_rounded, color: look.muted),
                onSelected: (value) {
                  switch (value) {
                    case 'files':
                      pickAndSendBundle(context, folder: false);
                    case 'folder':
                      pickAndSendBundle(context, folder: true);
                    case 'received':
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ReceivedScreen(),
                        ),
                      );
                    case 'scan':
                      _pickLibraryVideoToSend();
                    case 'share':
                      showNearbySheet(
                        context,
                        onSend: _pickLibraryVideoToSend,
                        pickFile: _chooseFileToSend,
                        onReceived: () =>
                            _reload(rescan: DesktopSupport.isWindows),
                      );
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'files', child: Text('Send files')),
                  PopupMenuItem(value: 'folder', child: Text('Send a folder')),
                  PopupMenuItem(
                    value: 'received',
                    child: Text('Received files'),
                  ),
                  PopupMenuItem(value: 'scan', child: Text('Scan code')),
                  PopupMenuItem(
                    value: 'share',
                    child: Text('All share options'),
                  ),
                ],
              ),
            ],
          ),
          NearbyDeviceChips(pills: true, pickFile: _chooseFileToSend),
          const UsbHint(),
        ],
      ),
    );
  }

  Widget _sourceSwitch(IconData sourceIcon, String sourceLabel) {
    final look = LibraryPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: look.card,
        borderRadius: BorderRadius.circular(LibraryPalette.radius),
        border: Border.all(color: look.border),
      ),
      child: Row(
        children: [
          Expanded(child: _sourceTab(0, sourceIcon, sourceLabel)),
          Expanded(child: _sourceTab(1, Icons.lock_rounded, 'Vault')),
        ],
      ),
    );
  }

  Widget _sourceTab(int value, IconData icon, String label) {
    final look = LibraryPalette.of(context);
    final on = _tab == value;
    return Material(
      color: on ? look.accent : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _selectTab(value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 16, color: on ? look.onAccent : look.muted),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: on ? look.onAccent : look.muted,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchField() {
    final look = LibraryPalette.of(context);
    return TextField(
      controller: _search,
      style: TextStyle(color: look.ink, fontSize: 13),
      cursorColor: look.accent,
      decoration: InputDecoration(
        hintText: 'Search by title',
        hintStyle: TextStyle(color: look.muted, fontSize: 13),
        prefixIcon: Icon(Icons.search_rounded, color: look.muted, size: 20),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                onPressed: _search.clear,
                icon: Icon(Icons.cancel_rounded, color: look.muted, size: 18),
              ),
        filled: true,
        fillColor: look.card,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        border: _searchBorder(look.border),
        enabledBorder: _searchBorder(look.border),
        focusedBorder: _searchBorder(look.accent),
      ),
    );
  }

  OutlineInputBorder _searchBorder(Color color) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(LibraryPalette.radius),
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
    final look = LibraryPalette.of(context);
    final fg = selected ? look.onAccent : (dashed ? look.accent : look.ink);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: selected ? look.accent : (dashed ? look.accentDim : look.card),
        shape: StadiumBorder(
          side: BorderSide(
            color: dashed
                ? look.accent.withValues(alpha: 0.5)
                : (selected ? look.accent : look.border),
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: iconColor ?? fg),
                  const SizedBox(width: 4),
                ],
                Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
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
      return VaultLockPane(onUnlocked: () => _reload());
    }
    if (_loading) return const SkeletonGrid();
    if (_error != null) {
      return LibraryEmpty(
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
      return _DeviceList(
        selected: _selected,
        selecting: _selectMode || _selected.isNotEmpty,
        favorites: catalog.favorites,
        onDelete: (video) => _deleteVideos([video]),
        onToggle: _toggleSelect,
        onFavorite: (video) => ref
            .read(libraryCatalogProvider.notifier)
            .toggleFavorite('device:${video.id}'),
        videos: _device.where(_matchesVideo).toList(),
        filtered:
            _query.trim().isNotEmpty ||
            _favoritesOnly ||
            _collection != null ||
            _platform != 'All',
        onPlay: _playDevice,
        onVault: (video) => _confirmVault(video),
        onActions: _deviceActions,
        onSend: _sendDevice,
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
    if (action == 'share' ||
        action == 'near' ||
        action == 'tv' ||
        action == 'handoff' ||
        action == 'sound') {
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
        .addToCollection(name, 'device:${video.id}');
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
    required this.onPlay,
    required this.onVault,
    required this.onActions,
    required this.onSend,
  });

  final ValueChanged<DeviceVideo> onSend;
  final Set<String> selected;
  final bool selecting;
  final Set<String> favorites;
  final ValueChanged<DeviceVideo> onDelete;
  final ValueChanged<DeviceVideo> onToggle;
  final ValueChanged<DeviceVideo> onFavorite;
  final List<DeviceVideo> videos;
  final bool filtered;
  final ValueChanged<DeviceVideo> onPlay;
  final ValueChanged<DeviceVideo> onVault;
  final ValueChanged<DeviceVideo> onActions;

  @override
  Widget build(BuildContext context) {
    if (videos.isEmpty) {
      if (filtered) {
        return const LibraryEmpty(
          icon: Icons.search_off_rounded,
          title: 'No videos match',
          message: 'Try another title, platform, or collection.',
        );
      }
      if (DesktopSupport.isWindows) {
        return const LibraryEmpty(
          icon: Icons.video_library_outlined,
          title: 'No videos found on this PC',
          message:
              'Add a folder with the folder button above, or download a video, then refresh.',
        );
      }
      return const LibraryEmpty(
        icon: Icons.play_circle_rounded,
        title: 'Your library is empty',
        message:
            'Download your favorite reels, shorts, and TikTok videos to watch offline anytime.',
      );
    }
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        _libraryGutter(context),
        4,
        _libraryGutter(context),
        24,
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.58,
      ),
      itemCount: videos.length,
      itemBuilder: (context, index) {
        final video = videos[index];
        final seconds = (video.durationMs / 1000).round();
        final when = libraryWhen(libraryAdded(video.addedAt));
        final folder = DesktopSupport.isWindows ? _folderName(video) : '';
        return _VideoCard(
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
        );
      },
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
        borderRadius: BorderRadius.circular(LibraryPalette.radius),
        side: BorderSide(
          color: missing
              ? Colors.transparent
              : selected
              ? look.accent
              : look.border,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: missing ? _missingThumb(look) : _thumb(context)),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: vault ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: missing ? look.muted : look.ink,
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
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
                        style: TextStyle(
                          fontSize: 10,
                          height: 1.3,
                          color: look.muted,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (missing && onDelete != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                child: TextButton.icon(
                  key: deleteKey,
                  style: TextButton.styleFrom(
                    foregroundColor: look.danger,
                    backgroundColor: look.dangerDim,
                    minimumSize: const Size.fromHeight(32),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_forever_rounded, size: 14),
                  label: const Text(
                    'Delete record',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: look.border)),
                  ),
                  child: vault ? _vaultActions(look) : _phoneActions(look),
                ),
              ),
          ],
        ),
      ),
    );
    if (!missing) return card;
    return DashedRoundedBorder(
      color: look.danger.withValues(alpha: 0.7),
      child: card,
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
        const DecoratedBox(decoration: BoxDecoration(color: Color(0x4D000000))),
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

  Widget _phoneActions(LibraryPalette look) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _actionIcon(
          Icons.phonelink_ring_rounded,
          'Send to another device',
          onSend,
          look,
        ),
        _actionIcon(Icons.lock_outline_rounded, 'Add to vault', onVault, look),
        _actionIcon(
          Icons.delete_outline_rounded,
          'Delete',
          onDelete,
          look,
          color: look.danger,
          buttonKey: deleteKey,
        ),
        _actionIcon(Icons.more_vert_rounded, 'More', onMore, look),
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
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
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
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
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
      return const LibraryEmpty(
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
        24,
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 260,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.92,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final path = paths[item.id];
        final missing =
            path == null || path.isEmpty || !File(path).existsSync();
        final when = libraryWhen(item.addedAt);
        final size = librarySize(item.bytes);
        return _VideoCard(
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
        );
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

class VaultLockPane extends ConsumerStatefulWidget {
  const VaultLockPane({super.key, this.onUnlocked});

  final VoidCallback? onUnlocked;

  @override
  ConsumerState<VaultLockPane> createState() => _VaultLockPaneState();
}

class _VaultLockPaneState extends ConsumerState<VaultLockPane>
    with SingleTickerProviderStateMixin {
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
    if (event is! KeyDownEvent && event is! KeyRepeatEvent)
      return KeyEventResult.ignored;
    final key = event.logicalKey;
    final ch = event.character;
    if (ch != null && ch.length == 1 && '0123456789'.contains(ch)) {
      _press(ch);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.delete) {
      _backspace();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
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
    final look = LibraryPalette.of(context);
    final vault = ref.watch(vaultServiceProvider);
    final creating = !vault.hasPin;
    final title = creating
        ? (_confirming ? 'Confirm Passcode' : 'Create Passcode')
        : 'Enter Vault PIN';
    final subtitle =
        _error ??
        (creating
            ? (_confirming
                  ? 'Enter the same 4 digits again'
                  : 'Choose 4 digits to lock your vault')
            : 'Enter your 4-digit security PIN to unlock');
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
        child: LayoutBuilder(
          builder: (context, box) {
            final keypad = _keypadSize(box.biggest);
            return Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.lock_rounded, color: look.accent, size: 18),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: look.ink,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: look.accentDim,
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(
                          color: look.accent.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Text(
                        'AES-256',
                        style: TextStyle(
                          color: look.accent,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _error != null ? look.danger : look.muted,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
                AnimatedBuilder(
                  animation: _shake,
                  builder: (context, child) {
                    final t = _shake.value;
                    final dx = t == 0
                        ? 0.0
                        : 14 * (1 - t) * math.sin(t * math.pi * 6);
                    return Transform.translate(
                      offset: Offset(dx, 0),
                      child: child,
                    );
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < _length; i++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          width: 12,
                          height: 12,
                          margin: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i < _pin.length
                                ? look.accent
                                : Colors.transparent,
                            border: Border.all(
                              color: i < _pin.length ? look.accent : look.muted,
                              width: 1.4,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const Spacer(),
                for (final row in const [
                  [
                    ['1', ''],
                    ['2', 'ABC'],
                    ['3', 'DEF'],
                  ],
                  [
                    ['4', 'GHI'],
                    ['5', 'JKL'],
                    ['6', 'MNO'],
                  ],
                  [
                    ['7', 'PQRS'],
                    ['8', 'TUV'],
                    ['9', 'WXYZ'],
                  ],
                ]) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var c = 0; c < 3; c++) ...[
                        if (c > 0) SizedBox(width: keypad.gap),
                        _PinKey(
                          digit: row[c][0],
                          letters: row[c][1],
                          size: keypad.size,
                          onTap: () => _press(row[c][0]),
                        ),
                      ],
                    ],
                  ),
                  SizedBox(height: keypad.gap),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(width: keypad.size, height: keypad.size),
                    SizedBox(width: keypad.gap),
                    _PinKey(
                      digit: '0',
                      letters: '',
                      size: keypad.size,
                      onTap: () => _press('0'),
                    ),
                    SizedBox(width: keypad.gap),
                    SizedBox(
                      width: keypad.size,
                      height: keypad.size,
                      child: TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: look.ink,
                          shape: const CircleBorder(),
                          padding: EdgeInsets.zero,
                        ),
                        onPressed: _pin.isEmpty ? _cancel : _backspace,
                        child: Text(
                          _pin.isEmpty ? 'Cancel' : 'Delete',
                          style: TextStyle(
                            fontSize: (keypad.size * 0.2).clamp(12.0, 16.0),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Keys grow with the space under the short header, and stop at a phone-sized cap.
  ({double size, double gap}) _keypadSize(Size box) {
    const header = 96.0;
    const minGap = 8.0;
    final freeH = math.max(1.0, box.height - header);
    final freeW = math.max(1.0, box.width);
    var size = math.min((freeH - minGap * 3) / 4, (freeW - minGap * 2) / 3);
    if (!size.isFinite || size <= 0) size = 48;
    if (size > 84) size = 84;
    var gap = math.min(
      20.0,
      math.min((freeH - size * 4) / 3, (freeW - size * 3) / 2),
    );
    if (!gap.isFinite || gap < 2) gap = 2;
    return (size: size, gap: gap);
  }
}

/// Round passcode key. Digit size follows the circle.
class _PinKey extends StatefulWidget {
  const _PinKey({
    required this.digit,
    required this.letters,
    required this.onTap,
    required this.size,
  });

  final String digit;
  final String letters;
  final VoidCallback onTap;
  final double size;

  @override
  State<_PinKey> createState() => _PinKeyState();
}

class _PinKeyState extends State<_PinKey> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final look = LibraryPalette.of(context);
    final size = widget.size;
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
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _down ? look.accentDim : look.raised,
          border: Border.all(color: look.border),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              widget.digit,
              style: TextStyle(
                color: look.ink,
                fontSize: size * 0.42,
                fontWeight: FontWeight.w400,
                height: 1,
              ),
            ),
            if (widget.letters.isNotEmpty)
              Text(
                widget.letters,
                style: TextStyle(
                  color: look.muted,
                  fontSize: (size * 0.11).clamp(7.0, 11.0),
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                  height: 1.1,
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
    backgroundColor: Theme.of(context).colorScheme.surface,
    showDragHandle: false,
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: math.min(MediaQuery.sizeOf(context).height * 0.92, 760),
        child: VaultLockPane(onUnlocked: () => Navigator.pop(context, true)),
      ),
    ),
  );
  return ok == true || ref.read(vaultUnlockedProvider);
}
