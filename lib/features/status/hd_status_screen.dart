import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/library/session_media_picker.dart';
import 'package:social_save/shared/widgets/liquid_glass.dart';
import 'package:social_save/shared/widgets/local_video_thumb.dart';

/// Home row that opens the HD status flow.
class HdStatusEntry extends StatelessWidget {
  const HdStatusEntry({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(Icons.hd_rounded, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'HD WhatsApp status',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: -0.2, color: scheme.onSurface),
                ),
                const SizedBox(height: 2),
                Text(
                  'Prepare a photo or video so the status stays sharp',
                  style: TextStyle(fontSize: 13, height: 1.3, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Icon(Icons.arrow_forward_rounded, color: scheme.onSurfaceVariant),
        ],
      ),
    );
    if (LiquidGlassScope.of(context)) {
      return GlassPress(
        onTap: () => context.push('/status'),
        borderRadius: BorderRadius.circular(22),
        semanticLabel: 'HD WhatsApp status. Prepare a photo or video so the status stays sharp',
        child: IosGlassPlate(dark: dark, radius: 22, child: child),
      );
    }
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: () => context.push('/status'),
        borderRadius: BorderRadius.circular(22),
        child: child,
      ),
    );
  }
}

class HdStatusScreen extends StatefulWidget {
  const HdStatusScreen({super.key});

  @override
  State<HdStatusScreen> createState() => _HdStatusScreenState();
}

class _HdStatusScreenState extends State<HdStatusScreen> {
  static const _channel = MethodChannel('socialsave/media');

  MediaKind _kind = MediaKind.video;
  List<MediaEntry> _items = const [];
  MediaEntry? _picked;
  bool _loading = false;
  bool _preparing = false;
  String _progress = '';
  String? _error;
  List<_StatusPart> _parts = const [];
  bool _clipped = false;
  bool _photo = false;
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load(MediaKind kind) async {
    if (!Plat.isAndroid) return;
    setState(() {
      _kind = kind;
      _picked = null;
      _parts = const [];
      _error = null;
      _loading = true;
      _items = const [];
    });
    final access = await MediaCatalog.ensureAccess(kind);
    if (!mounted) return;
    if (access == 'denied') {
      setState(() {
        _loading = false;
        _error = 'Allow photo and video access to choose a status.';
      });
      return;
    }
    try {
      await for (final list in MediaCatalog.load(kind)) {
        if (!mounted || _kind != kind) return;
        setState(() => _items = list.length > 80 ? list.sublist(0, 80) : list);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not open the gallery.');
    } finally {
      if (mounted && _kind == kind) setState(() => _loading = false);
    }
  }

  Future<void> _prepare() async {
    final item = _picked;
    if (item == null || _preparing) return;
    setState(() {
      _preparing = true;
      _error = null;
      _parts = const [];
      _progress = 'Opening the file';
    });
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 700), (_) async {
      try {
        final text = await _channel.invokeMethod<String>('statusProgress');
        if (mounted && text != null && text.isNotEmpty) setState(() => _progress = text);
      } catch (_) {}
    });
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('statusPrepare', {
        'path': item.path,
        'uri': item.uri,
        'photo': item.kind == MediaKind.image,
      });
      final list = (raw?['parts'] as List?) ?? const [];
      final parts = <_StatusPart>[
        for (final it in list.whereType<Map<Object?, Object?>>())
          if ((it['path'] as String?)?.isNotEmpty == true)
            _StatusPart(
              path: it['path'] as String,
              part: (it['part'] as num?)?.toInt() ?? 1,
              total: (it['total'] as num?)?.toInt() ?? 1,
              bytes: (it['bytes'] as num?)?.toInt() ?? 0,
            ),
      ];
      if (!mounted) return;
      setState(() {
        _parts = parts;
        _clipped = raw?['clipped'] == true;
        _photo = raw?['photo'] == true;
        _progress = '';
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message ?? 'Could not prepare that file.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not prepare that file.');
    } finally {
      _tick?.cancel();
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _share(_StatusPart part, {required bool business}) async {
    try {
      final code = await _channel.invokeMethod<String>('statusShare', {
        'path': part.path,
        'business': business,
      });
      if (!mounted) return;
      if (code == 'missing_app') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(business ? 'WhatsApp Business is not installed.' : 'WhatsApp is not installed.')),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open WhatsApp.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 4),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => context.pop(),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  Expanded(
                    child: Text(
                      'HD WhatsApp status',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                    child: Text(
                      'Pick a photo or video. Social Save prepares it, then you post that file to your status. It does not add a fade, and it does not invent detail that was not in the original.',
                      style: TextStyle(height: 1.4, color: scheme.onSurfaceVariant),
                    ),
                  ),
                  if (!Plat.isAndroid)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                      child: Text(
                        'This runs on the phone, next to WhatsApp. Open Social Save there, choose the photo or video, then share the prepared file to your status.',
                        style: TextStyle(height: 1.4, color: scheme.onSurface),
                      ),
                    )
                  else ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                      child: Row(
                        children: [
                          Expanded(child: FilledButton.tonalIcon(
                            onPressed: _preparing ? null : () => _load(MediaKind.video),
                            icon: const Icon(Icons.movie_outlined),
                            label: const Text('Video'),
                          )),
                          const SizedBox(width: 10),
                          Expanded(child: FilledButton.tonalIcon(
                            onPressed: _preparing ? null : () => _load(MediaKind.image),
                            icon: const Icon(Icons.photo_outlined),
                            label: const Text('Photo'),
                          )),
                        ],
                      ),
                    ),
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.only(top: 14),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    if (_picked != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(_picked!.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 10),
                            FilledButton(
                              onPressed: _preparing ? null : _prepare,
                              child: Text(_preparing ? _progress.ifEmpty('Preparing') : 'Prepare'),
                            ),
                            if (_preparing) ...[
                              const SizedBox(height: 10),
                              const LinearProgressIndicator(),
                            ],
                          ],
                        ),
                      ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                        child: Text(_error!, style: TextStyle(color: scheme.error, height: 1.35)),
                      ),
                    if (_parts.isNotEmpty)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 280),
                        child: ListView(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                          children: [
                            Text(
                              _photo
                                  ? 'The photo is a short video now. Post it as a status and do not crop it again in WhatsApp.'
                                  : _parts.length == 1
                                      ? 'Ready. Post this file as your status and do not crop it again in WhatsApp.'
                                      : 'Ready in ${_parts.length} parts of 30 seconds. Post them in order.',
                              style: TextStyle(height: 1.4, color: scheme.onSurface),
                            ),
                            if (_clipped)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  'Only the first 10 minutes were prepared.',
                                  style: TextStyle(color: scheme.onSurfaceVariant),
                                ),
                              ),
                            for (final part in _parts) ...[
                              const SizedBox(height: 12),
                              Text(
                                part.total == 1 ? _sizeLabel(part.bytes) : 'Part ${part.part} of ${part.total} · ${_sizeLabel(part.bytes)}',
                                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                              ),
                              const SizedBox(height: 8),
                              FilledButton.icon(
                                onPressed: () => _share(part, business: false),
                                icon: const Icon(Icons.send_rounded),
                                label: Text(part.total == 1 ? 'Share to WhatsApp' : 'Share part ${part.part}'),
                              ),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton(
                                  onPressed: () => _share(part, business: true),
                                  child: const Text('WhatsApp Business'),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    if (_items.isNotEmpty)
                      Expanded(
                        child: GridView.builder(
                          padding: const EdgeInsets.fromLTRB(20, 14, 20, 120),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 8,
                          ),
                          itemCount: _items.length,
                          itemBuilder: (context, i) {
                            final item = _items[i];
                            final selected = _picked?.key == item.key;
                            return GestureDetector(
                              onTap: _preparing ? null : () => setState(() {
                                _picked = item;
                                _parts = const [];
                                _error = null;
                              }),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: selected ? scheme.primary : Colors.transparent,
                                    width: selected ? 3 : 2,
                                  ),
                                ),
                                child: LocalVideoThumb(
                                  cacheKey: item.key,
                                  id: 'status_${item.kind.name}_${item.id}',
                                  path: item.path,
                                  uri: item.uri,
                                  borderRadius: 14,
                                ),
                              ),
                            );
                          },
                        ),
                      )
                    else if (!_loading && _picked == null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                        child: Text(
                          'Choose Video or Photo, tap one, then Prepare.',
                          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _sizeLabel(int bytes) {
    if (bytes <= 0) return '';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB';
  }
}

class _StatusPart {
  const _StatusPart({
    required this.path,
    required this.part,
    required this.total,
    required this.bytes,
  });

  final String path;
  final int part;
  final int total;
  final int bytes;
}

extension on String {
  String ifEmpty(String fallback) => trim().isEmpty ? fallback : this;
}
