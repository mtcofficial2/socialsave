// The web build's Library, Vault and player. Videos saved from this browser
// live in IndexedDB (see web_saver_web.dart); titles, favourites, notes,
// collections and the Vault flag live in shared preferences.
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/downloads/presentation/providers/downloads_controller.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';
import 'package:social_save/shared/models/download_status.dart';
import 'package:social_save/shared/widgets/platform_logo.dart';
import 'package:social_save/shared/widgets/video_thumbnail.dart';
import 'package:social_save/web/web_pages.dart';
import 'package:social_save/web/web_saver.dart';
import 'package:social_save/web/web_video.dart';

// ---------------------------------------------------------------- metadata

class WebItemMeta {
  const WebItemMeta({
    this.title,
    this.favorite = false,
    this.note = '',
    this.collection = '',
    this.vault = false,
  });

  final String? title;
  final bool favorite;
  final String note;
  final String collection;
  final bool vault;

  WebItemMeta copyWith({
    String? title,
    bool? favorite,
    String? note,
    String? collection,
    bool? vault,
  }) {
    return WebItemMeta(
      title: title ?? this.title,
      favorite: favorite ?? this.favorite,
      note: note ?? this.note,
      collection: collection ?? this.collection,
      vault: vault ?? this.vault,
    );
  }

  Map<String, Object?> toJson() => {
        'title': title,
        'favorite': favorite,
        'note': note,
        'collection': collection,
        'vault': vault,
      };

  factory WebItemMeta.fromJson(Map<String, Object?> json) => WebItemMeta(
        title: json['title'] as String?,
        favorite: json['favorite'] == true,
        note: json['note'] as String? ?? '',
        collection: json['collection'] as String? ?? '',
        vault: json['vault'] == true,
      );
}

final webLibraryProvider =
    NotifierProvider<WebLibraryController, Map<String, WebItemMeta>>(WebLibraryController.new);

class WebLibraryController extends Notifier<Map<String, WebItemMeta>> {
  static const _key = 'web_library_meta';
  static const _pinKey = 'web_vault_pin';

  @override
  Map<String, WebItemMeta> build() {
    unawaited(_load());
    return const {};
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      state = {
        for (final e in data.entries)
          e.key: WebItemMeta.fromJson(Map<String, Object?>.from(e.value as Map)),
      };
    } catch (_) {}
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode({for (final e in state.entries) e.key: e.value.toJson()}),
    );
  }

  WebItemMeta of(String id) => state[id] ?? const WebItemMeta();

  Future<void> update(String id, WebItemMeta Function(WebItemMeta) change) async {
    state = {...state, id: change(of(id))};
    await _save();
  }

  Future<void> remove(String id) async {
    state = {...state}..remove(id);
    await _save();
  }

  // Vault PIN: a salted SHA-256 hash, never the PIN itself.
  static String _hash(String pin) =>
      sha256.convert(utf8.encode('socialsave-web-vault:$pin')).toString();

  Future<bool> hasPin() async =>
      (await SharedPreferences.getInstance()).getString(_pinKey) != null;

  Future<void> setPin(String pin) async =>
      (await SharedPreferences.getInstance()).setString(_pinKey, _hash(pin));

  Future<bool> checkPin(String pin) async =>
      (await SharedPreferences.getInstance()).getString(_pinKey) == _hash(pin);
}

String webTitle(DownloadRecord r, WebItemMeta m) {
  final t = m.title?.trim() ?? '';
  return t.isNotEmpty ? t : r.title;
}

String webFileName(DownloadRecord r, WebItemMeta m) {
  var base = webTitle(r, m).replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]+'), ' ').trim();
  if (base.isEmpty) base = 'SocialSave video';
  if (base.length > 80) base = base.substring(0, 80).trim();
  return '$base.${(r.format ?? 'mp4').toLowerCase()}';
}

// ---------------------------------------------------------------- player

class WebPlayerArgs {
  const WebPlayerArgs({required this.items, this.index = 0});

  final List<WebPlayItem> items;
  final int index;
}

class WebPlayItem {
  const WebPlayItem({required this.title, this.url, this.recordId, this.sourceUrl});

  final String title;
  final String? url;
  final String? recordId;
  final String? sourceUrl;
}

/// Opens the web player for [records] starting at [index].
Future<void> openWebPlayer(
  BuildContext context,
  WidgetRef? ref,
  List<DownloadRecord> records,
  int index,
) async {
  final meta = ref?.read(webLibraryProvider) ?? const <String, WebItemMeta>{};
  final items = [
    for (final r in records)
      WebPlayItem(
        title: webTitle(r, meta[r.id] ?? const WebItemMeta()),
        recordId: r.id,
        url: r.localPath,
        sourceUrl: r.sourceUrl,
      ),
  ];
  await context.push('/player', extra: WebPlayerArgs(items: items, index: index));
}

class WebPlayerScreen extends ConsumerStatefulWidget {
  const WebPlayerScreen({super.key, required this.args});

  final WebPlayerArgs args;

  @override
  ConsumerState<WebPlayerScreen> createState() => _WebPlayerScreenState();
}

class _WebPlayerScreenState extends ConsumerState<WebPlayerScreen> {
  late int _index = widget.args.index;
  String? _url;
  String? _error;
  WebVideoHandle? _handle;
  Timer? _countdown;
  int _left = 0;

  WebPlayItem get _item => widget.args.items[_index];
  bool get _hasNext => _index < widget.args.items.length - 1;
  bool get _hasPrev => _index > 0;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  @override
  void dispose() {
    _countdown?.cancel();
    super.dispose();
  }

  Future<void> _resolve() async {
    _countdown?.cancel();
    setState(() {
      _url = null;
      _error = null;
      _left = 0;
    });
    final item = _item;
    String? url;
    if (item.url != null && webCanPlay(item.url!)) url = item.url;
    if (url == null && item.recordId != null) {
      url = await webStoredVideoUrl(item.recordId!);
    }
    if (url == null && item.url != null && item.url!.startsWith('http')) url = item.url;
    if (!mounted) return;
    setState(() {
      _url = url;
      _error = url == null
          ? 'This video is in your browser\'s Downloads folder but not stored in the site. Open it from Downloads, or save the link again.'
          : null;
    });
  }

  void _go(int index) {
    setState(() => _index = index);
    unawaited(_resolve());
  }

  void _ended() {
    final autoNext = ref.read(settingsControllerProvider).autoPlayNextInGallery;
    if (!autoNext || !_hasNext || !mounted) return;
    setState(() => _left = 5);
    _countdown = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      if (_left <= 1) {
        t.cancel();
        _go(_index + 1);
      } else {
        setState(() => _left--);
      }
    });
  }

  Future<void> _share() async {
    final item = _item;
    final ok = await webShare(
      title: item.title,
      url: item.sourceUrl,
      fileKey: item.recordId,
      fileName: '${item.title}.mp4',
    );
    if (!ok && item.sourceUrl != null) {
      await Clipboard.setData(ClipboardData(text: item.sourceUrl!));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link copied.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(_item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (_item.recordId != null)
            IconButton(
              tooltip: 'Save to this device again',
              icon: const Icon(Icons.download_rounded),
              onPressed: () async {
                final ok = await webSaveStoredVideo(_item.recordId!, '${_item.title}.mp4');
                if (!ok && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('No stored copy in this browser.')),
                  );
                }
              },
            ),
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: _share,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (url != null)
                    WebVideoView(
                      key: ValueKey(url),
                      url: url,
                      onEnded: _ended,
                      onReady: (h) => _handle = h,
                    )
                  else if (_error != null)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70, height: 1.4),
                        ),
                      ),
                    )
                  else
                    const Center(child: CircularProgressIndicator()),
                  if (_left > 0)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 70,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Expanded(child: Text('Next video in $_left s')),
                              TextButton(
                                onPressed: () {
                                  _countdown?.cancel();
                                  setState(() => _left = 0);
                                  _handle?.restart();
                                },
                                child: const Text('Rewatch'),
                              ),
                              FilledButton(
                                onPressed: () => _go(_index + 1),
                                child: const Text('Play now'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (widget.args.items.length > 1)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      color: Colors.white,
                      tooltip: 'Previous',
                      onPressed: _hasPrev ? () => _go(_index - 1) : null,
                      icon: const Icon(Icons.skip_previous_rounded),
                    ),
                    Text(
                      '${_index + 1} / ${widget.args.items.length}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    IconButton(
                      color: Colors.white,
                      tooltip: 'Next',
                      onPressed: _hasNext ? () => _go(_index + 1) : null,
                      icon: const Icon(Icons.skip_next_rounded),
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

// ---------------------------------------------------------------- library

class WebLibraryScreen extends ConsumerStatefulWidget {
  const WebLibraryScreen({super.key});

  @override
  ConsumerState<WebLibraryScreen> createState() => _WebLibraryScreenState();
}

class _WebLibraryScreenState extends ConsumerState<WebLibraryScreen> {
  String _filter = 'all';
  bool _vaultOpen = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = ref.watch(downloadsControllerProvider);
    final meta = ref.watch(webLibraryProvider);
    final saved = rows.maybeWhen(
      data: (items) => items.where((r) => r.status == DownloadStatus.completed).toList(),
      orElse: () => const <DownloadRecord>[],
    );
    WebItemMeta m(DownloadRecord r) => meta[r.id] ?? const WebItemMeta();
    final open = saved.where((r) => !m(r).vault).toList();
    final vaulted = saved.where((r) => m(r).vault).toList();
    final collections = {
      for (final r in open)
        if (m(r).collection.trim().isNotEmpty) m(r).collection.trim(),
    }.toList()
      ..sort();
    if (_filter != 'all' && _filter != 'fav' && !collections.contains(_filter)) {
      _filter = 'all';
    }
    final shown = _vaultOpen
        ? vaulted
        : open.where((r) {
            if (_filter == 'fav') return m(r).favorite;
            if (_filter != 'all') return m(r).collection.trim() == _filter;
            return true;
          }).toList();

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Row(
              children: [
                if (_vaultOpen)
                  IconButton(
                    tooltip: 'Lock the Vault',
                    onPressed: () => setState(() => _vaultOpen = false),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                Expanded(
                  child: Text(
                    _vaultOpen ? 'Vault' : 'Library',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                  ),
                ),
                if (_vaultOpen)
                  TextButton.icon(
                    onPressed: () => setState(() => _vaultOpen = false),
                    icon: const Icon(Icons.lock_rounded, size: 18),
                    label: const Text('Lock'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _vaultOpen
                  ? 'Private videos, locked with your PIN in this browser.'
                  : 'Videos saved from this browser. They play here, even after you close the page.',
              style: TextStyle(fontSize: 13, height: 1.4, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            if (!_vaultOpen) ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _chip('all', 'All (${open.length})'),
                    _chip('fav', 'Favorites'),
                    for (final c in collections) _chip(c, c),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
            if (rows.isLoading && saved.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (shown.isEmpty)
              _EmptyCard(
                text: _vaultOpen
                    ? 'The Vault is empty. Use "Move to Vault" on a video.'
                    : _filter == 'all'
                        ? 'Nothing saved yet. Analyze a public link to start.'
                        : 'No videos here yet.',
                onHome: _vaultOpen ? null : () => context.go('/'),
              )
            else
              for (var i = 0; i < shown.length; i++)
                _LibraryRow(
                  record: shown[i],
                  meta: m(shown[i]),
                  inVault: _vaultOpen,
                  onPlay: () => openWebPlayer(context, ref, shown, i),
                ),
            if (!_vaultOpen) ...[
              const SizedBox(height: 16),
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  key: const ValueKey('web-vault-open'),
                  leading: Icon(Icons.lock_rounded, color: scheme.primary),
                  title: const Text('Vault', style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text('${vaulted.length} private ${vaulted.length == 1 ? 'video' : 'videos'} · PIN locked'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _unlockVault,
                ),
              ),
              const SizedBox(height: 12),
              const WebAppsCard(
                icon: Icons.folder_open_rounded,
                title: 'Videos already on your device',
                detail:
                    'The phone and PC apps also list the videos already in your folders. A website cannot scan your folders.',
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chip(String id, String label) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: _filter == id,
        onSelected: (_) => setState(() => _filter = id),
      ),
    );
  }

  Future<void> _unlockVault() async {
    final controller = ref.read(webLibraryProvider.notifier);
    final hasPin = await controller.hasPin();
    if (!mounted) return;
    final ok = await showWebPinPad(
      context,
      setup: !hasPin,
      check: controller.checkPin,
      save: controller.setPin,
    );
    if (ok && mounted) setState(() => _vaultOpen = true);
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.text, this.onHome});

  final String text;
  final VoidCallback? onHome;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(Icons.video_library_rounded, size: 40, color: scheme.primary),
            const SizedBox(height: 8),
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
            if (onHome != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onHome,
                icon: const Icon(Icons.add_link_rounded),
                label: const Text('Save a video'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LibraryRow extends ConsumerWidget {
  const _LibraryRow({
    required this.record,
    required this.meta,
    required this.inVault,
    required this.onPlay,
  });

  final DownloadRecord record;
  final WebItemMeta meta;
  final bool inVault;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final lib = ref.read(webLibraryProvider.notifier);
    final title = webTitle(record, meta);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onPlay,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 2, 10),
            child: Row(
              children: [
                SizedBox(
                  width: 104,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      VideoThumbnail(
                        url: record.thumbnailUrl,
                        height: 60,
                        borderRadius: 12,
                        durationSeconds: record.durationSeconds,
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          shape: BoxShape.circle,
                        ),
                        padding: const EdgeInsets.all(4),
                        child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 22),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, height: 1.3),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          PlatformLogo(platform: record.platform, size: 14),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              meta.collection.isNotEmpty
                                  ? meta.collection
                                  : record.platform.displayName,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                      if (meta.note.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            meta.note,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: scheme.onSurfaceVariant),
                          ),
                        ),
                    ],
                  ),
                ),
                if (!inVault)
                  IconButton(
                    tooltip: meta.favorite ? 'Remove from favorites' : 'Add to favorites',
                    onPressed: () => lib.update(record.id, (m) => m.copyWith(favorite: !m.favorite)),
                    icon: Icon(
                      meta.favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                      color: meta.favorite ? Colors.amber : scheme.onSurfaceVariant,
                    ),
                  ),
                PopupMenuButton<String>(
                  tooltip: 'More',
                  onSelected: (v) => _action(context, ref, v),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'play', child: ListTile(leading: Icon(Icons.play_arrow_rounded), title: Text('Play'))),
                    if (!inVault) ...const [
                      PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.edit_rounded), title: Text('Rename'))),
                      PopupMenuItem(value: 'note', child: ListTile(leading: Icon(Icons.sticky_note_2_outlined), title: Text('Note'))),
                      PopupMenuItem(value: 'collection', child: ListTile(leading: Icon(Icons.folder_outlined), title: Text('Collection'))),
                      PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.ios_share_rounded), title: Text('Share'))),
                    ],
                    const PopupMenuItem(value: 'save', child: ListTile(leading: Icon(Icons.download_rounded), title: Text('Save to device again'))),
                    PopupMenuItem(
                      value: 'vault',
                      child: ListTile(
                        leading: Icon(inVault ? Icons.lock_open_rounded : Icons.lock_rounded),
                        title: Text(inVault ? 'Move out of Vault' : 'Move to Vault'),
                      ),
                    ),
                    const PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline_rounded), title: Text('Delete'))),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _action(BuildContext context, WidgetRef ref, String action) async {
    final lib = ref.read(webLibraryProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    switch (action) {
      case 'play':
        onPlay();
      case 'rename':
        final v = await _ask(context, 'Rename', webTitle(record, meta));
        if (v != null && v.trim().isNotEmpty) {
          await lib.update(record.id, (m) => m.copyWith(title: v.trim()));
        }
      case 'note':
        final v = await _ask(context, 'Note', meta.note, lines: 3);
        if (v != null) await lib.update(record.id, (m) => m.copyWith(note: v.trim()));
      case 'collection':
        final v = await _ask(context, 'Collection name (empty to remove)', meta.collection);
        if (v != null) await lib.update(record.id, (m) => m.copyWith(collection: v.trim()));
      case 'share':
        final ok = await webShare(
          title: webTitle(record, meta),
          url: record.sourceUrl,
          fileKey: record.id,
          fileName: webFileName(record, meta),
        );
        if (!ok) {
          await Clipboard.setData(ClipboardData(text: record.sourceUrl));
          messenger.showSnackBar(const SnackBar(content: Text('Link copied.')));
        }
      case 'save':
        final ok = await webSaveStoredVideo(record.id, webFileName(record, meta));
        messenger.showSnackBar(
          SnackBar(
            content: Text(ok
                ? 'Saved to your browser\'s Downloads.'
                : 'No stored copy in this browser. Open the link again to save it.'),
          ),
        );
      case 'vault':
        await lib.update(record.id, (m) => m.copyWith(vault: !inVault));
        messenger.showSnackBar(
          SnackBar(content: Text(inVault ? 'Moved out of the Vault.' : 'Moved to the Vault.')),
        );
      case 'delete':
        if (!context.mounted) return;
        final sure = await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(
            title: const Text('Delete this video?'),
            content: const Text('It is removed from this site. A copy already in your Downloads folder stays there.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Delete')),
            ],
          ),
        );
        if (sure == true) {
          await ref.read(downloadsControllerProvider.notifier).delete(record.id, deleteFile: true);
          await lib.remove(record.id);
        }
    }
  }
}

Future<String?> _ask(BuildContext context, String title, String initial, {int lines = 1}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        minLines: lines,
        maxLines: lines,
        onSubmitted: lines == 1 ? (v) => Navigator.pop(d, v) : null,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(d, controller.text), child: const Text('Save')),
      ],
    ),
  );
}

// ---------------------------------------------------------------- PIN pad

/// iPhone-style 4-digit keypad. [setup] asks for a new PIN twice.
Future<bool> showWebPinPad(
  BuildContext context, {
  required bool setup,
  required Future<bool> Function(String) check,
  required Future<void> Function(String) save,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _PinPad(setup: setup, check: check, save: save),
  );
  return ok == true;
}

class _PinPad extends StatefulWidget {
  const _PinPad({required this.setup, required this.check, required this.save});

  final bool setup;
  final Future<bool> Function(String) check;
  final Future<void> Function(String) save;

  @override
  State<_PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<_PinPad> {
  String _pin = '';
  String? _first;
  String? _error;

  String get _title {
    if (!widget.setup) return 'Enter Vault PIN';
    return _first == null ? 'Choose a 4-digit PIN' : 'Enter the PIN again';
  }

  Future<void> _tap(String digit) async {
    if (_pin.length >= 4) return;
    setState(() {
      _pin += digit;
      _error = null;
    });
    if (_pin.length < 4) return;
    final pin = _pin;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    if (widget.setup) {
      if (_first == null) {
        setState(() {
          _first = pin;
          _pin = '';
        });
      } else if (_first == pin) {
        await widget.save(pin);
        if (mounted) Navigator.pop(context, true);
      } else {
        setState(() {
          _first = null;
          _pin = '';
          _error = 'The PINs did not match. Try again.';
        });
      }
      return;
    }
    if (await widget.check(pin)) {
      if (mounted) Navigator.pop(context, true);
    } else if (mounted) {
      unawaited(HapticFeedback.heavyImpact());
      setState(() {
        _pin = '';
        _error = 'Wrong PIN.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget key(String label, {VoidCallback? onTap, Widget? child}) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Material(
          color: child == null ? scheme.surfaceContainerHighest : Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            key: ValueKey('pin-$label'),
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 64,
              height: 64,
              child: Center(
                child: child ??
                    Text(label, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w500)),
              ),
            ),
          ),
        ),
      );
    }

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_rounded, color: scheme.primary),
            const SizedBox(height: 8),
            Text(_title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < 4; i++)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i < _pin.length ? scheme.primary : Colors.transparent,
                      border: Border.all(color: scheme.primary, width: 1.5),
                    ),
                  ),
              ],
            ),
            SizedBox(
              height: 26,
              child: Center(
                child: Text(_error ?? '', style: TextStyle(color: scheme.error, fontSize: 13)),
              ),
            ),
            for (final row in const [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
            ])
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [for (final d in row) key(d, onTap: () => _tap(d))],
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                key('cancel', onTap: () => Navigator.pop(context, false), child: const Text('Cancel')),
                key('0', onTap: () => _tap('0')),
                key(
                  'del',
                  onTap: _pin.isEmpty ? null : () => setState(() => _pin = _pin.substring(0, _pin.length - 1)),
                  child: const Icon(Icons.backspace_outlined),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
