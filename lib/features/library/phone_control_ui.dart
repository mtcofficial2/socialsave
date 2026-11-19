import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:social_save/features/library/phone_control.dart';
import 'package:social_save/features/library/usb_link.dart';

/// Opens control for a phone that is plugged in with USB debugging allowed.
Future<void> showPhoneControl(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => const FractionallySizedBox(
      heightFactor: 0.92,
      child: PhoneControlSheet(),
    ),
  );
}

/// The computer's view of the plugged-in phone.
class PhoneControlSheet extends StatefulWidget {
  const PhoneControlSheet({
    super.key,
    this.previewPhones,
    this.previewApps,
    this.previewNamed = true,
  });

  /// Used by tests. A live sheet reads the phones on the USB cable.
  final List<({String serial, String name})>? previewPhones;
  final List<PhoneControlApp>? previewApps;
  final bool previewNamed;

  bool get preview => previewPhones != null;

  @override
  State<PhoneControlSheet> createState() => _PhoneControlSheetState();
}

class _PhoneControlSheetState extends State<PhoneControlSheet> {
  Timer? _timer;
  final _search = TextEditingController();
  final _type = TextEditingController();
  List<({String serial, String name})> _phones = const [];
  List<PhoneControlApp> _apps = const [];
  String _serial = '';
  String _loadedSerial = '';
  String _note = '';
  Uint8List? _shot;
  int _imageW = 1080;
  int _imageH = 2400;
  bool _named = true;
  bool _appsReady = false;
  bool _busy = false;
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    if (widget.preview) {
      _phones = widget.previewPhones!;
      _serial = _phones.isEmpty ? '' : _phones.first.serial;
      _apps = widget.previewApps ?? const [];
      _named = widget.previewNamed;
      _appsReady = true;
      return;
    }
    _phones = UsbLink.phones();
    _serial = _phones.isEmpty ? '' : _phones.first.serial;
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      _syncPhones();
      unawaited(_capture());
    });
    unawaited(_loadApps());
    unawaited(_capture());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _search.dispose();
    _type.dispose();
    super.dispose();
  }

  void _syncPhones() {
    if (!mounted || widget.preview) return;
    final phones = UsbLink.phones();
    final serials = phones.map((phone) => phone.serial).join('\n');
    final had = _phones.map((phone) => phone.serial).join('\n');
    if (serials == had && phones.any((phone) => phone.serial == _serial)) return;
    final next = phones.any((phone) => phone.serial == _serial) ? _serial : (phones.isEmpty ? '' : phones.first.serial);
    final changed = next != _serial;
    setState(() {
      _phones = phones;
      _serial = next;
      if (changed) {
        _shot = null;
        _apps = const [];
        _appsReady = false;
        _loadedSerial = '';
      }
    });
    if (changed) unawaited(_loadApps());
  }

  Future<void> _loadApps() async {
    if (widget.preview || _serial.isEmpty) return;
    if (_loadedSerial == _serial && _appsReady) return;
    final serial = _serial;
    final result = await UsbLink.phoneApps(serial);
    if (!mounted || serial != _serial) return;
    setState(() {
      _loadedSerial = serial;
      _apps = result.apps;
      _named = result.named;
      _appsReady = true;
    });
  }

  Future<void> _capture() async {
    if (widget.preview || _serial.isEmpty || _capturing) return;
    _capturing = true;
    try {
      final bytes = await UsbLink.phoneShot(_serial);
      if (!mounted || bytes == null) return;
      final size = pngSize(bytes);
      if (size == null) return;
      setState(() {
        _shot = bytes;
        _imageW = size.$1;
        _imageH = size.$2;
      });
    } finally {
      _capturing = false;
    }
  }

  Future<void> _act(Future<bool> Function() action, String ok, String fail) async {
    if (_busy || _serial.isEmpty) return;
    setState(() => _busy = true);
    var worked = widget.preview;
    try {
      if (!widget.preview) worked = await action();
    } catch (_) {
      worked = false;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = worked ? ok : fail;
    });
    if (worked && !widget.preview) unawaited(_capture());
  }

  Future<void> _sendType() async {
    final text = phoneControlType(_type.text);
    _type.clear();
    if (text.isEmpty) {
      setState(() => _note = 'Type some words first.');
      return;
    }
    await _act(
      () => UsbLink.phoneType(_serial, text),
      'Typed into the open field.',
      'The phone did not take those words.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final phone = _phones.where((item) => item.serial == _serial).firstOrNull;
    return Material(
      color: Colors.transparent,
      child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Control the phone', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Open an app, tap the picture, or type. The phone shows the same actions. Words you type are not saved.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.35),
              ),
              const SizedBox(height: 12),
              if (_phones.isEmpty)
                Text(
                  'Plug in a phone with Social Save open and USB debugging allowed.',
                  style: theme.textTheme.bodyMedium,
                )
              else ...[
                if (_phones.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: DropdownButton<String>(
                      value: _serial,
                      items: [
                        for (final item in _phones)
                          DropdownMenuItem(value: item.serial, child: Text(item.name)),
                      ],
                      onChanged: (serial) {
                        if (serial == null || serial == _serial) return;
                        setState(() {
                          _serial = serial;
                          _shot = null;
                          _apps = widget.preview ? (widget.previewApps ?? const []) : const [];
                          _appsReady = widget.preview;
                          _loadedSerial = '';
                          _note = '';
                        });
                        unawaited(_loadApps());
                        unawaited(_capture());
                      },
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(phone?.name ?? 'Phone', style: theme.textTheme.titleMedium),
                  ),
                Expanded(child: _work(theme, scheme)),
              ],
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _work(ThemeData theme, ColorScheme scheme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        final screen = _screen(theme, scheme);
        final apps = _appColumn(theme, scheme);
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 3, child: screen),
              const SizedBox(width: 16),
              SizedBox(width: 280, child: apps),
            ],
          );
        }
        return Column(
          children: [
            SizedBox(height: constraints.maxHeight * 0.52, child: screen),
            const SizedBox(height: 8),
            Expanded(child: apps),
          ],
        );
      },
    );
  }

  Widget _screen(ThemeData theme, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return GestureDetector(
                    key: const ValueKey('phone-control-screen'),
                    onTapUp: (details) {
                      final point = phoneControlTap(
                        localX: details.localPosition.dx,
                        localY: details.localPosition.dy,
                        boxW: constraints.maxWidth,
                        boxH: constraints.maxHeight,
                        imageW: _imageW,
                        imageH: _imageH,
                      );
                      if (point == null) return;
                      unawaited(_act(
                        () => UsbLink.phoneTap(_serial, point.x, point.y),
                        'Tapped the phone screen.',
                        'The phone did not take that tap.',
                      ));
                    },
                    child: _shot == null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                widget.preview ? 'Phone screen' : 'Reading the phone screen…',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                          )
                        : Image.memory(
                            _shot!,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                            width: constraints.maxWidth,
                            height: constraints.maxHeight,
                          ),
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final key in const [('back', 'Back'), ('home', 'Home'), ('recents', 'Recents')])
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: OutlinedButton(
                    key: ValueKey('phone-control-${key.$1}'),
                    onPressed: _busy
                        ? null
                        : () => _act(
                              () => UsbLink.phoneKey(_serial, key.$1),
                              'Pressed ${key.$2}.',
                              'The phone did not take ${key.$2}.',
                            ),
                    child: Text(key.$2),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('phone-control-type'),
                controller: _type,
                textInputAction: TextInputAction.send,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'Type on the phone',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => unawaited(_sendType()),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('phone-control-type-send'),
              onPressed: _busy ? null : () => unawaited(_sendType()),
              child: const Text('Type'),
            ),
          ],
        ),
        if (_note.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(_note, key: const ValueKey('phone-control-note'), style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }

  Widget _appColumn(ThemeData theme, ColorScheme scheme) {
    final shown = [for (final app in _apps) if (phoneControlMatches(app, _search.text)) app];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Apps', style: theme.textTheme.titleMedium)),
            IconButton(
              tooltip: 'Refresh apps',
              onPressed: widget.preview
                  ? null
                  : () {
                      _loadedSerial = '';
                      setState(() => _appsReady = false);
                      unawaited(_loadApps());
                    },
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        TextField(
          key: const ValueKey('phone-control-search'),
          controller: _search,
          decoration: const InputDecoration(
            isDense: true,
            hintText: 'Search apps',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Expanded(child: _appList(theme, scheme, shown)),
      ],
    );
  }

  Widget _appList(ThemeData theme, ColorScheme scheme, List<PhoneControlApp> shown) {
    if (!_appsReady) {
      return Text('Reading apps on the phone…', style: theme.textTheme.bodyMedium);
    }
    if (!_named) {
      return Text(
        'Update Social Save on the phone to see app names. You can still tap the screen, use Back, Home, and Recents, and type.',
        style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
      );
    }
    if (_apps.isEmpty) {
      return Text('This phone has no launchable apps Social Save can open.', style: theme.textTheme.bodyMedium);
    }
    if (shown.isEmpty) {
      return Text('No app matches that search.', style: theme.textTheme.bodyMedium);
    }
    return ListView.builder(
      itemCount: shown.length,
      itemBuilder: (context, index) {
        final app = shown[index];
        return ListTile(
          key: ValueKey('phone-control-app-${app.packageName}'),
          contentPadding: EdgeInsets.zero,
          title: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            app.system ? 'System · ${app.packageName}' : app.packageName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          onTap: _busy
              ? null
              : () => _act(
                    () => UsbLink.openPhoneApp(_serial, app.packageName),
                    'Opened ${app.name}.',
                    'The phone did not open ${app.name}.',
                  ),
        );
      },
    );
  }
}
