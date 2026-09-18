import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
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
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
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
                              videos: _device,
                              onPlay: _playDevice,
                              onVault: (video) => _confirmVault(video),
                            )
                          : _VaultGate(
                              items: _vault,
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
  });

  final List<DeviceVideo> videos;
  final ValueChanged<DeviceVideo> onPlay;
  final ValueChanged<DeviceVideo> onVault;

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
      color: scheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(18),
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
  final _controller = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _controller.text.trim();
    if (pin.length < 4 || pin.length > 8 || int.tryParse(pin) == null) {
      setState(() => _error = 'Use a 4–8 digit PIN.');
      return;
    }
    final vault = ref.read(vaultServiceProvider);
    await HapticFeedback.lightImpact();
    if (!vault.hasPin) {
      if (pin != _confirm.text.trim()) {
        setState(() => _error = 'PINs do not match.');
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
    setState(() => _error = 'Wrong PIN.');
  }

  @override
  Widget build(BuildContext context) {
    final vault = ref.watch(vaultServiceProvider);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: ListView(
        shrinkWrap: true,
        children: [
          const SizedBox(height: 8),
          Center(
            child: CircleAvatar(
              radius: 36,
              backgroundColor: scheme.primaryContainer,
              child: const Icon(Icons.lock_rounded, color: Colors.white, size: 32),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            vault.hasPin ? 'Enter vault PIN' : 'Create a vault PIN',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            vault.hasPin
                ? 'Videos in the vault stay inside SocialSave. Other apps cannot see them.'
                : 'Choose a 4–8 digit PIN. You will need it to open the vault.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 8,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24, letterSpacing: 8),
            decoration: InputDecoration(
              counterText: '',
              hintText: '••••',
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (!vault.hasPin) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _confirm,
              keyboardType: TextInputType.number,
              obscureText: true,
              maxLength: 8,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, letterSpacing: 8),
              decoration: const InputDecoration(
                counterText: '',
                hintText: 'Confirm PIN',
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _submit,
            child: Text(vault.hasPin ? 'Unlock' : 'Save PIN'),
          ),
          const SizedBox(height: 8),
        ],
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
        height: 480,
        child: VaultLockPane(
          onUnlocked: () => Navigator.pop(context, true),
        ),
      ),
    ),
  );
  return ok == true || ref.read(vaultUnlockedProvider);
}
