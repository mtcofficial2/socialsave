import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:social_save/features/library/device_media.dart';
import 'package:social_save/features/library/vault_service.dart';
import 'package:social_save/features/player/open_player.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/widgets/brand_header.dart';
import 'package:social_save/shared/widgets/empty_state.dart';
import 'package:social_save/shared/widgets/local_video_thumb.dart';

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
  int _tab = 0;
  bool _loading = true;
  String? _error;
  String _query = '';
  String _platform = 'All';
  List<DeviceVideo> _device = [];
  List<VaultItem> _vault = [];
  final Map<String, String> _vaultPaths = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      ref.read(vaultUnlockedProvider.notifier).state = false;
    }
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final videos = await Permission.videos.request();
    final storage = await Permission.storage.request();
    final allowed =
        videos.isGranted || videos.isLimited || storage.isGranted || storage.isLimited;
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
        _error = 'Could not load videos on this phone.';
        _loading = false;
      });
    }
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
    await openPreviewPlayer(
      context,
      PlayerSession(
        title: video.title,
        platform: SocialPlatform.direct,
        filePath: path,
        queue: queue,
        queueIndex: index < 0 ? 0 : index,
      ),
    );
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
    await openPreviewPlayer(
      context,
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
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const BrandHeader(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Library',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontSize: 20,
                          ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: scheme.brightness == Brightness.dark
                      ? const Color(0x661C2633)
                      : const Color(0xB3FFFFFF),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.55)),
                ),
                child: Row(
                  children: [
                    _seg('On this phone', 0),
                    _seg('Vault', 1),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                onChanged: (value) => setState(() => _query = value),
                decoration: const InputDecoration(
                  hintText: 'Search by title',
                  prefixIcon: Icon(Icons.search_rounded),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
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
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? EmptyState(
                          icon: Icons.videocam_off_outlined,
                          title: 'Cannot open library',
                          message: _error!,
                        )
                      : _tab == 0
                          ? _DeviceList(
                              videos: _device.where(_matchesVideo).toList(),
                              onPlay: _playDevice,
                              onVault: (video) => _confirmVault(video),
                              onActions: _deviceActions,
                            )
                          : _VaultGate(
                              items: _vault.where(_matchesVault).toList(),
                              paths: _vaultPaths,
                              onPlay: _playVault,
                              onActions: _vaultItemActions,
                              onReload: _reload,
                            ),
            ),
          ],
        ),
      ),
    );
  }

  bool _matchesVideo(DeviceVideo video) {
    return _matchesText('${video.title} ${video.path ?? ''}');
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

  Widget _seg(String label, int value) {
    final selected = _tab == value;
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Material(
        color: selected ? scheme.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () => setState(() => _tab = value),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
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
              subtitle: const Text('Put it back in On this phone and remove it from the vault'),
              onTap: () => Navigator.pop(context, 'move'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('Keep a copy in Library'),
              subtitle: const Text('Show it in On this phone and keep the vault copy locked'),
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

  Future<void> _deviceActions(DeviceVideo video) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(video.title), subtitle: Text(_durationLabel((video.durationMs / 1000).round(), video.size))),
            ListTile(
              leading: const Icon(Icons.play_arrow_rounded),
              title: const Text('Play'),
              onTap: () => Navigator.pop(context, 'play'),
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
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Details'),
              onTap: () => Navigator.pop(context, 'details'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
              title: const Text('Delete from phone'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
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
    if (action == 'share') {
      final path = await DeviceMediaService().resolvePlayablePath(video);
      if (path == null || !mounted) return;
      await Share.shareXFiles([XFile(path)], text: video.title);
      return;
    }
    if (action == 'details') {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(video.title),
          content: Text(
            '${_durationLabel((video.durationMs / 1000).round(), video.size)}\n${video.path ?? video.uri ?? ''}',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
          ],
        ),
      );
      return;
    }
    if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete this video?'),
          content: Text('“${video.title}” will be removed from this phone.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
          ],
        ),
      );
      if (ok != true) return;
      final deleted = await DeviceMediaService().deletePublic(video);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(deleted ? 'Deleted.' : 'Could not delete this video.')),
      );
      await _reload();
    }
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
              subtitle: const Text('Keep the original on this phone'),
              onTap: () => Navigator.pop(context, 'copy'),
            ),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('Move to vault'),
              subtitle: const Text('Remove it from Gallery and Files'),
              onTap: () => Navigator.pop(context, 'move'),
            ),
          ],
        ),
      ),
    );
    if (action == 'copy') await _addToVault(video, move: false);
    if (action == 'move') await _addToVault(video, move: true);
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({
    required this.videos,
    required this.onPlay,
    required this.onVault,
    required this.onActions,
  });

  final List<DeviceVideo> videos;
  final ValueChanged<DeviceVideo> onPlay;
  final ValueChanged<DeviceVideo> onVault;
  final ValueChanged<DeviceVideo> onActions;

  @override
  Widget build(BuildContext context) {
    if (videos.isEmpty) {
      return const EmptyState(
        icon: Icons.video_library_outlined,
        title: 'No videos on this phone',
        message: 'Download a video or copy one onto the device, then refresh.',
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: MediaQuery.sizeOf(context).width >= 700 ? 3 : 2,
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
          caption: _durationLabel(seconds, video.size),
          durationLabel: _clock(seconds),
          onTap: () => onPlay(video),
          onLongPress: () => onActions(video),
          action: IconButton(
            tooltip: 'Add to vault',
            onPressed: () => onVault(video),
            icon: const Icon(Icons.lock_outline, color: Colors.white),
          ),
        );
      },
    );
  }
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
                  LocalVideoThumb(
                    cacheKey: cacheKey,
                    id: id,
                    path: path,
                    uri: uri,
                    borderRadius: 0,
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
                              fontSize: 11,
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
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                  if (caption != null)
                    Text(
                      caption!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
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
              message: 'Open On this phone, then tap the lock icon to hide a video behind your PIN.',
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
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
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

class _VaultLockPaneState extends ConsumerState<VaultLockPane> {
  static const _length = 4;
  String _pin = '';
  String _first = '';
  bool _confirming = false;
  String? _error;

  Future<void> _press(String digit) async {
    if (_pin.length >= _length) return;
    HapticFeedback.selectionClick();
    setState(() {
      _pin += digit;
      _error = null;
    });
    if (_pin.length == _length) {
      await _submit(_pin);
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
        setState(() {
          _error = 'PINs do not match. Enter 4 digits again.';
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
    setState(() {
      _error = 'Wrong PIN.';
      _pin = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final vault = ref.watch(vaultServiceProvider);
    final scheme = Theme.of(context).colorScheme;
    final creating = !vault.hasPin;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
      child: Column(
        children: [
          CircleAvatar(
            radius: 32,
            backgroundColor: scheme.primaryContainer,
            child: const Icon(Icons.lock_rounded, color: Colors.white, size: 28),
          ),
          const SizedBox(height: 12),
          Text(
            creating
                ? (_confirming ? 'Confirm your PIN' : 'Create a vault PIN')
                : 'Enter vault PIN',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            creating
                ? '4 digits only. You will need them to open the vault.'
                : 'Videos in the vault stay inside SocialSave.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < _length; i++)
                Container(
                  width: 14,
                  height: 14,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < _pin.length ? scheme.primary : scheme.surfaceContainerHighest,
                  ),
                ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: scheme.error)),
          ],
          const SizedBox(height: 12),
          for (final row in const [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
          ])
            Row(
              children: [
                for (final digit in row)
                  Expanded(child: _PinKey(label: digit, onTap: () => _press(digit))),
              ],
            ),
          Row(
            children: [
              const Expanded(child: SizedBox(height: 64)),
              Expanded(child: _PinKey(label: '0', onTap: () => _press('0'))),
              Expanded(
                child: _PinKey(
                  icon: Icons.backspace_outlined,
                  onTap: _backspace,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PinKey extends StatelessWidget {
  const _PinKey({this.label, this.icon, required this.onTap});

  final String? label;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: SizedBox(
        height: 56,
        child: FilledButton.tonal(
          onPressed: onTap,
          child: icon != null ? Icon(icon) : Text(label!, style: const TextStyle(fontSize: 22)),
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
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: 560,
        child: VaultLockPane(
          onUnlocked: () => Navigator.pop(context, true),
        ),
      ),
    ),
  );
  return ok == true || ref.read(vaultUnlockedProvider);
}
