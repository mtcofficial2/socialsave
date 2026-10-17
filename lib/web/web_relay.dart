// Web "nearby share": send a file through the SocialSave server with a
// 6-character code (or QR), receive it on another device by entering the
// code or opening the QR link. Files expire after 30 minutes or 3 downloads.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:social_save/core/config/env_config.dart';
import 'package:social_save/core/config/hosted_api.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/features/downloads/presentation/providers/downloads_controller.dart';
import 'package:social_save/shared/models/download_status.dart';
import 'package:social_save/web/web_library.dart';
import 'package:social_save/web/web_pages.dart';
import 'package:social_save/web/web_saver.dart';

const _maxBytes = 200 * 1024 * 1024;

String get _api {
  final base = EnvConfig.apiBaseUrl;
  return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
}

/// Web relay links always point at the hosted site (web build only).
String relayReceiveLink(String code) => '${HostedApi.origin}/?receive=$code';

String _size(int bytes) {
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

String _message(String body, String fallback) {
  try {
    final data = jsonDecode(body) as Map<String, dynamic>;
    final error = data['error'];
    if (error is Map && error['message'] is String) return error['message'] as String;
  } catch (_) {}
  return fallback;
}

/// The Home screen's nearby-share card on the web.
class WebRelayCard extends StatelessWidget {
  const WebRelayCard({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.wifi_tethering_rounded, color: scheme.primary),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Nearby share', style: TextStyle(fontWeight: FontWeight.w700)),
                      SizedBox(height: 2),
                      Text(
                        'Send a video or file to another phone or PC with a code.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('relay-send'),
                    onPressed: () => showRelaySend(context),
                    icon: const Icon(Icons.north_east_rounded, size: 18),
                    label: const Text('Send'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('relay-receive'),
                    onPressed: () => showRelayReceive(context),
                    icon: const Icon(Icons.south_west_rounded, size: 18),
                    label: const Text('Receive'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- send

Future<void> showRelaySend(BuildContext context) async {
  final picked = await showModalBottomSheet<WebPickedFile>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _SendPicker(),
  );
  if (picked == null || !context.mounted) return;
  if (picked.size > _maxBytes) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('That file is over the 200 MB limit.')),
    );
    return;
  }
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UploadDialog(file: picked),
  );
}

class _SendPicker extends ConsumerWidget {
  const _SendPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(downloadsControllerProvider);
    final meta = ref.watch(webLibraryProvider);
    final saved = rows.maybeWhen(
      data: (items) => items
          .where((r) => r.status == DownloadStatus.completed && !(meta[r.id]?.vault ?? false))
          .toList(),
      orElse: () => const <DownloadRecord>[],
    );
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            const Text('Send to another device',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text(
              'Up to 200 MB. The code works for 30 minutes or 3 downloads.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            ListTile(
              key: const ValueKey('relay-pick-file'),
              contentPadding: EdgeInsets.zero,
              leading: const CircleAvatar(child: Icon(Icons.upload_file_rounded)),
              title: const Text('Choose a file from this device'),
              onTap: () {
                // The chooser must open inside the tap.
                final pick = webPickFile();
                pick.then((file) {
                  if (file != null && context.mounted) Navigator.pop(context, file);
                });
              },
            ),
            if (saved.isNotEmpty) ...[
              const Divider(),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text('Saved videos', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              for (final r in saved)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(child: Icon(Icons.movie_rounded)),
                  title: Text(
                    webTitle(r, meta[r.id] ?? const WebItemMeta()),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () async {
                    final file = await webStoredFile(
                      r.id,
                      webFileName(r, meta[r.id] ?? const WebItemMeta()),
                    );
                    if (!context.mounted) return;
                    if (file == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('No stored copy of that video in this browser.')),
                      );
                      return;
                    }
                    Navigator.pop(context, file);
                  },
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _UploadDialog extends StatefulWidget {
  const _UploadDialog({required this.file});

  final WebPickedFile file;

  @override
  State<_UploadDialog> createState() => _UploadDialogState();
}

class _UploadDialogState extends State<_UploadDialog> {
  double? _progress;
  String? _code;
  String? _error;

  @override
  void initState() {
    super.initState();
    _upload();
  }

  Future<void> _upload() async {
    setState(() {
      _error = null;
      _progress = 0;
    });
    final (status, body) = await webHttp(
      'POST',
      '$_api/relay',
      upload: widget.file,
      onProgress: (sent, total) {
        if (mounted && total > 0) setState(() => _progress = sent / total);
      },
    );
    if (!mounted) return;
    if (status == 200) {
      try {
        final data = jsonDecode(body) as Map<String, dynamic>;
        setState(() => _code = data['code'] as String);
        return;
      } catch (_) {}
    }
    setState(() => _error = status == 0
        ? 'Could not reach the server. Check your connection.'
        : _message(body, 'The upload failed. Try again.'));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final code = _code;
    return AlertDialog(
      title: Text(code == null ? 'Sending...' : 'Ready to receive'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${widget.file.name} · ${_size(widget.file.size)}',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 14),
            if (_error != null)
              Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: scheme.error))
            else if (code == null) ...[
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 8),
              Text('${((_progress ?? 0) * 100).round()}%'),
            ] else ...[
              SelectableText(
                code,
                key: const ValueKey('relay-code'),
                style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: 6),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(8),
                color: Colors.white,
                child: QrImageView(data: relayReceiveLink(code), size: 170),
              ),
              const SizedBox(height: 10),
              Text(
                'On the other device open ${HostedApi.displayHost}, tap Receive and enter the code, or scan the QR.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_error != null)
          TextButton(onPressed: _upload, child: const Text('Try again')),
        if (code != null) ...[
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: relayReceiveLink(code)));
              webToast('Link copied.');
            },
            child: const Text('Copy link'),
          ),
          TextButton(
            onPressed: () async {
              final ok = await webShare(title: 'SocialSave code $code', url: relayReceiveLink(code));
              if (!ok) {
                await Clipboard.setData(ClipboardData(text: relayReceiveLink(code)));
                webToast('Link copied.');
              }
            },
            child: const Text('Share'),
          ),
        ],
        FilledButton(
          onPressed: code == null && _error == null ? null : () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- receive

Future<void> showRelayReceive(BuildContext context, {String? code}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ReceiveDialog(initial: code),
  );
}

class _ReceiveDialog extends StatefulWidget {
  const _ReceiveDialog({this.initial});

  final String? initial;

  @override
  State<_ReceiveDialog> createState() => _ReceiveDialogState();
}

class _ReceiveDialogState extends State<_ReceiveDialog> {
  late final _controller = TextEditingController(text: widget.initial ?? '');
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _info;

  @override
  void initState() {
    super.initState();
    if ((widget.initial ?? '').length == 6) _lookup();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _code => _controller.text.trim().toUpperCase();

  Future<void> _lookup() async {
    if (_code.length != 6) {
      setState(() => _error = 'The code has 6 letters and numbers.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final (status, body) = await webHttp('GET', '$_api/relay/$_code');
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (status == 200) {
        _info = jsonDecode(body) as Map<String, dynamic>;
      } else {
        _error = status == 0
            ? 'Could not reach the server. Check your connection.'
            : _message(body, 'That code has expired or is wrong.');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final info = _info;
    final type = (info?['content_type'] as String?) ?? '';
    final playable = type.startsWith('video/') || type.startsWith('audio/');
    final fileUrl = '$_api/relay/$_code/file';
    return AlertDialog(
      title: const Text('Receive'),
      content: SizedBox(
        width: 300,
        child: info == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const ValueKey('relay-code-input'),
                    controller: _controller,
                    autofocus: true,
                    maxLength: 6,
                    textCapitalization: TextCapitalization.characters,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 26, letterSpacing: 6, fontWeight: FontWeight.w700),
                    decoration: const InputDecoration(hintText: 'K7P2QX', counterText: ''),
                    onSubmitted: (_) => _lookup(),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: scheme.error)),
                    ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(playable ? Icons.movie_rounded : Icons.insert_drive_file_rounded,
                      size: 40, color: scheme.primary),
                  const SizedBox(height: 8),
                  Text(
                    info['name'] as String? ?? 'file',
                    key: const ValueKey('relay-file-name'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_size((info['size'] as num?)?.toInt() ?? 0)} · ${info['downloads_left']} downloads left',
                    style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        if (info == null)
          FilledButton(
            key: const ValueKey('relay-lookup'),
            onPressed: _busy ? null : _lookup,
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Find'),
          )
        else ...[
          if (playable)
            TextButton(
              key: const ValueKey('relay-watch'),
              onPressed: () {
                final name = info['name'] as String? ?? 'Video';
                Navigator.pop(context);
                context.push(
                  '/player',
                  extra: WebPlayerArgs(items: [WebPlayItem(title: name, url: fileUrl)]),
                );
              },
              child: const Text('Watch'),
            ),
          FilledButton(
            key: const ValueKey('relay-download'),
            onPressed: () {
              webOpenDownload('$fileUrl?dl=1', info['name'] as String? ?? 'file');
              Navigator.pop(context);
              webToast('Downloading ${info['name']}');
            },
            child: const Text('Download'),
          ),
        ],
      ],
    );
  }
}
