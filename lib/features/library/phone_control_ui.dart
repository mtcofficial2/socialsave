import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/library/phone_control.dart';
import 'package:social_save/features/library/phone_control_open.dart';
import 'package:social_save/features/library/usb_link.dart';

/// Opens control for a phone that is plugged in with USB debugging allowed.
/// On Windows this is its own window. The sheet is the fallback.
Future<void> showPhoneControl(BuildContext context) async {
  if (Plat.isWindows) {
    final opened = await openPhoneControlWindow();
    if (opened || !context.mounted) return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => const FractionallySizedBox(
      heightFactor: 0.96,
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
    this.windowed = false,
  });

  /// Used by tests. A live sheet reads the phones on the USB cable.
  final List<({String serial, String name})>? previewPhones;
  final List<PhoneControlApp>? previewApps;
  final bool previewNamed;

  /// True when this sheet is the body of the control window.
  final bool windowed;

  bool get preview => previewPhones != null;

  @override
  State<PhoneControlSheet> createState() => _PhoneControlSheetState();
}

class _Job {
  _Job(this.action, {this.ok, this.fail, this.motion = false});

  final Future<bool> Function() action;
  final String? ok;
  final String? fail;
  final bool motion;
}

class _PhoneControlSheetState extends State<PhoneControlSheet> {
  Timer? _timer;
  Timer? _shotTimer;
  final _search = TextEditingController();
  final _type = TextEditingController();
  final _screenFocus = FocusNode();
  final List<_Job> _jobs = [];
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
  bool _capturing = false;
  bool _pumping = false;
  bool _finger = false;
  bool _secondary = false;
  String _problem = '';
  String _burst = '';
  double _wheel = 0;
  Offset? _wheelAt;
  double _wheelW = 0;
  double _wheelH = 0;
  Timer? _burstTimer;
  Timer? _wheelTimer;
  Offset? _from;
  Offset? _to;
  DateTime? _pressedAt;

  @override
  void initState() {
    super.initState();
    _screenFocus.addListener(() {
      if (mounted) setState(() {});
    });
    if (widget.preview) {
      _phones = widget.previewPhones!;
      _serial = _phones.isEmpty ? '' : _phones.first.serial;
      _apps = widget.previewApps ?? const [];
      _named = widget.previewNamed;
      _appsReady = true;
      return;
    }
    _phones = UsbLink.phones();
    _problem = UsbLink.controlProblem;
    _serial = _phones.isEmpty ? '' : _phones.first.serial;
    _timer = Timer.periodic(const Duration(milliseconds: 1600), (_) {
      _syncPhones();
      unawaited(_capture());
    });
    unawaited(_loadApps());
    unawaited(_capture());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _shotTimer?.cancel();
    _burstTimer?.cancel();
    _wheelTimer?.cancel();
    _search.dispose();
    _type.dispose();
    _screenFocus.dispose();
    super.dispose();
  }

  void _syncPhones() {
    if (!mounted || widget.preview) return;
    final phones = UsbLink.phones();
    final problem = UsbLink.controlProblem;
    final serials = phones.map((phone) => phone.serial).join('\n');
    final had = _phones.map((phone) => phone.serial).join('\n');
    final samePhone = phones.isEmpty ? _serial.isEmpty : phones.any((phone) => phone.serial == _serial);
    if (serials == had && problem == _problem && samePhone) return;
    final next = phones.any((phone) => phone.serial == _serial) ? _serial : (phones.isEmpty ? '' : phones.first.serial);
    final changed = next != _serial;
    setState(() {
      _phones = phones;
      _problem = problem;
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

  void _scheduleShot() {
    _shotTimer?.cancel();
    _shotTimer = Timer(const Duration(milliseconds: 240), () {
      if (mounted) unawaited(_capture());
    });
  }

  Future<bool> _captureNow() async {
    if (widget.preview || _serial.isEmpty) return false;
    await _capture(force: true);
    return _shot != null;
  }

  Future<void> _capture({bool force = false}) async {
    if (widget.preview || _serial.isEmpty || _capturing || _finger) return;
    if (!force && (_pumping || _jobs.isNotEmpty)) return;
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

  void _run(Future<bool> Function() action, String ok, String fail, {bool motion = false, bool quiet = false}) {
    if (_serial.isEmpty) return;
    if (widget.preview) {
      if (!quiet) setState(() => _note = ok);
      return;
    }
    if (motion) _jobs.removeWhere((job) => job.motion);
    if (_jobs.length >= 8) {
      final drop = _jobs.indexWhere((job) => job.motion);
      _jobs.removeAt(drop >= 0 ? drop : 0);
    }
    _jobs.add(_Job(action, ok: quiet ? null : ok, fail: quiet ? null : fail, motion: motion));
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (mounted && _jobs.isNotEmpty) {
        final job = _jobs.removeAt(0);
        var worked = false;
        try {
          worked = await job.action();
        } catch (_) {
          worked = false;
        }
        if (!mounted) return;
        if (job.ok != null) {
          setState(() => _note = worked ? job.ok! : (job.fail ?? job.ok!));
        }
        if (worked) _scheduleShot();
      }
    } finally {
      _pumping = false;
      if (mounted && _jobs.isNotEmpty) unawaited(_pump());
    }
  }

  void _sendMotion(PhoneMotionEvent? event, {bool quiet = false}) {
    if (event == null) return;
    switch (event.motion) {
      case PhoneMotion.tap:
        _run(() => UsbLink.phoneTap(_serial, event.x1, event.y1), 'Tapped the phone screen.', 'The phone did not take that tap.', motion: true, quiet: quiet);
      case PhoneMotion.hold:
        _run(
          () => UsbLink.phoneSwipe(_serial, event.x1, event.y1, event.x2, event.y2, event.ms),
          'Held on the phone screen.',
          'The phone did not take that hold.',
          motion: true,
          quiet: quiet,
        );
      case PhoneMotion.swipe:
        _run(
          () => UsbLink.phoneSwipe(_serial, event.x1, event.y1, event.x2, event.y2, event.ms),
          quiet ? 'Scrolled the phone screen.' : 'Swiped the phone screen.',
          'The phone did not take that swipe.',
          motion: true,
          quiet: quiet,
        );
    }
  }

  void _flushWheel() {
    final dy = _wheel;
    final at = _wheelAt;
    _wheel = 0;
    _wheelAt = null;
    if (at == null || dy == 0) return;
    _sendMotion(phoneControlWheel(
      localX: at.dx,
      localY: at.dy,
      boxW: _wheelW,
      boxH: _wheelH,
      imageW: _imageW,
      imageH: _imageH,
      deltaY: dy,
    ), quiet: true);
  }

  void _rememberChar(String text) {
    if (text.isEmpty) return;
    _burst = phoneControlBurst('$_burst$text');
    _burstTimer?.cancel();
    _burstTimer = Timer(const Duration(milliseconds: 40), _flushBurst);
  }

  void _flushBurst() {
    _burstTimer?.cancel();
    final text = _burst;
    _burst = '';
    if (text.isEmpty) return;
    _run(() => UsbLink.phoneWrite(_serial, text), 'Typed on the phone.', 'The phone did not take that key.', quiet: true);
  }

  void _sendKey(PhoneKeyPress press) {
    if (press.kind != PhoneKeyKind.character) _flushBurst();
    switch (press.kind) {
      case PhoneKeyKind.character:
        _rememberChar(press.text);
        return;
      case PhoneKeyKind.back:
        _run(() => UsbLink.phoneKey(_serial, 'back'), 'Pressed Back.', 'The phone did not take Back.');
      case PhoneKeyKind.enter:
        _run(() => UsbLink.phoneKey(_serial, 'enter'), 'Pressed Enter.', 'The phone did not take Enter.', quiet: true);
      case PhoneKeyKind.backspace:
        _run(() => UsbLink.phoneKey(_serial, 'backspace'), 'Pressed Backspace.', 'The phone did not take Backspace.', quiet: true);
      case PhoneKeyKind.delete:
        _run(() => UsbLink.phoneKey(_serial, 'delete'), 'Pressed Delete.', 'The phone did not take Delete.', quiet: true);
      case PhoneKeyKind.up:
        _run(() => UsbLink.phoneKey(_serial, 'up'), 'Pressed Up.', 'The phone did not take Up.', quiet: true);
      case PhoneKeyKind.down:
        _run(() => UsbLink.phoneKey(_serial, 'down'), 'Pressed Down.', 'The phone did not take Down.', quiet: true);
      case PhoneKeyKind.left:
        _run(() => UsbLink.phoneKey(_serial, 'left'), 'Pressed Left.', 'The phone did not take Left.', quiet: true);
      case PhoneKeyKind.right:
        _run(() => UsbLink.phoneKey(_serial, 'right'), 'Pressed Right.', 'The phone did not take Right.', quiet: true);
      case PhoneKeyKind.tab:
        _run(() => UsbLink.phoneKey(_serial, 'tab'), 'Pressed Tab.', 'The phone did not take Tab.', quiet: true);
      case PhoneKeyKind.volumeUp:
        _run(() => UsbLink.phoneKey(_serial, 'volumeUp'), 'Turned the volume up.', 'The phone did not change the volume.', quiet: true);
      case PhoneKeyKind.volumeDown:
        _run(() => UsbLink.phoneKey(_serial, 'volumeDown'), 'Turned the volume down.', 'The phone did not change the volume.', quiet: true);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final press = phoneControlKey(
      name: event.logicalKey.debugName,
      character: event.character ?? '',
      shortcut: keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed,
    );
    if (press == null) return KeyEventResult.ignored;
    _sendKey(press);
    return KeyEventResult.handled;
  }

  void _finishPointer(Offset up, double boxW, double boxH) {
    final from = _from;
    final started = _pressedAt;
    final secondary = _secondary;
    setState(() {
      _finger = false;
      _from = null;
      _to = null;
      _pressedAt = null;
      _secondary = false;
    });
    if (secondary || from == null || started == null) return;
    _sendMotion(phoneControlMotion(
      downX: from.dx,
      downY: from.dy,
      upX: up.dx,
      upY: up.dy,
      elapsedMs: DateTime.now().difference(started).inMilliseconds,
      boxW: boxW,
      boxH: boxH,
      imageW: _imageW,
      imageH: _imageH,
    ));
  }

  Future<void> _sendType() async {
    final text = phoneControlType(_type.text);
    _type.clear();
    _screenFocus.requestFocus();
    if (text.isEmpty) {
      setState(() => _note = 'Type some words first.');
      return;
    }
    _run(() => UsbLink.phoneType(_serial, text), 'Typed into the open field.', 'The phone did not take those words.');
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
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, widget.windowed ? 16 : 0, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('Control the phone', style: theme.textTheme.titleLarge)),
                    if (_phones.length > 1)
                      DropdownButton<String>(
                        value: _serial,
                        items: [
                          for (final item in _phones) DropdownMenuItem(value: item.serial, child: Text(item.name)),
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
                      )
                    else if (phone != null)
                      Text(phone.name, style: theme.textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Drag to scroll, use the wheel, and type while the screen is selected. Right-click or Esc goes back. Words you type are not saved.',
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.35),
                ),
                const SizedBox(height: 10),
                if (_phones.isEmpty)
                  Text(
                    _problem.isEmpty ? 'Plug in a phone with Social Save open and USB debugging allowed.' : _problem,
                    style: theme.textTheme.bodyMedium,
                  )
                else
                  Expanded(child: _work(theme, scheme)),
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
        final wide = constraints.maxWidth >= 760;
        final screen = _screen(theme, scheme);
        final apps = _appColumn(theme, scheme);
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 5, child: screen),
              const SizedBox(width: 18),
              SizedBox(width: 300, child: apps),
            ],
          );
        }
        return Column(
          children: [
            SizedBox(height: constraints.maxHeight * 0.62, child: screen),
            const SizedBox(height: 8),
            Expanded(child: apps),
          ],
        );
      },
    );
  }

  Widget _screen(ThemeData theme, ColorScheme scheme) {
    return Column(
      children: [
        Expanded(child: _bezel(theme)),
        const SizedBox(height: 10),
        _nav(),
        const SizedBox(height: 8),
        _typeRow(),
        const SizedBox(height: 4),
        SizedBox(
          height: 18,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(_note, key: const ValueKey('phone-control-note'), style: theme.textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
    );
  }

  Widget _bezel(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const padX = 14.0;
        const padTop = 16.0;
        const padBottom = 12.0;
        const earH = 16.0;
        const gap = 8.0;
        const labelH = 16.0;
        final innerW = math.max(48.0, constraints.maxWidth - padX * 2);
        final innerH = math.max(48.0, constraints.maxHeight - padTop - padBottom - earH - gap - labelH);
        final aspect = _imageW / _imageH;
        var picW = innerW;
        var picH = picW / aspect;
        if (picH > innerH) {
          picH = innerH;
          picW = picH * aspect;
        }
        return Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF161616),
              borderRadius: BorderRadius.circular(36),
              boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 28, offset: Offset(0, 14))],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(padX, padTop, padX, padBottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: picW,
                    height: earH,
                    child: Center(
                      child: Container(
                        width: 72,
                        height: 5,
                        decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                  ),
                  SizedBox(width: picW, height: picH, child: _picture(theme)),
                  const SizedBox(height: gap),
                  SizedBox(
                    width: picW,
                    height: labelH,
                    child: Text(
                      _screenFocus.hasFocus ? 'Keyboard is going to the phone' : 'Click the screen to type on the phone',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _picture(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Focus(
            focusNode: _screenFocus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: Listener(
              key: const ValueKey('phone-control-screen'),
              onPointerDown: (event) {
                _screenFocus.requestFocus();
                if (event.buttons == kSecondaryMouseButton) {
                  setState(() => _secondary = true);
                  _run(() => UsbLink.phoneKey(_serial, 'back'), 'Pressed Back.', 'The phone did not take Back.');
                  return;
                }
                setState(() {
                  _finger = true;
                  _secondary = false;
                  _from = event.localPosition;
                  _to = event.localPosition;
                  _pressedAt = DateTime.now();
                });
              },
              onPointerMove: (event) {
                if (_secondary || _from == null) return;
                setState(() => _to = event.localPosition);
              },
              onPointerUp: (event) => _finishPointer(event.localPosition, constraints.maxWidth, constraints.maxHeight),
              onPointerCancel: (event) => _finishPointer(event.localPosition, constraints.maxWidth, constraints.maxHeight),
              onPointerSignal: (event) {
                if (event is! PointerScrollEvent || _finger) return;
                _screenFocus.requestFocus();
                _wheel += event.scrollDelta.dy;
                _wheelAt = event.localPosition;
                _wheelW = constraints.maxWidth;
                _wheelH = constraints.maxHeight;
                _wheelTimer?.cancel();
                _wheelTimer = Timer(const Duration(milliseconds: 50), _flushWheel);
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: const Color(0xFF0C0C0C),
                      child: _shot == null
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Text(
                                  widget.preview ? 'Phone screen' : 'Reading the phone screen…',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
                                ),
                              ),
                            )
                          : Image.memory(_shot!, fit: BoxFit.fill, gaplessPlayback: true),
                    ),
                    if (_from != null && _to != null)
                      CustomPaint(
                        painter: _FingerStroke(_from!, _to!),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
    );
  }

  Widget _nav() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(28),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _navButton('back', 'Back', Icons.arrow_back_rounded, () => UsbLink.phoneKey(_serial, 'back'), 'Pressed Back.', 'The phone did not take Back.'),
            _navButton('home', 'Home', Icons.circle_outlined, () => UsbLink.phoneKey(_serial, 'home'), 'Pressed Home.', 'The phone did not take Home.'),
            _navButton('recents', 'Recent apps', Icons.crop_square_rounded, () => UsbLink.phoneKey(_serial, 'recents'), 'Pressed Recents.', 'The phone did not take Recents.'),
            _navButton('wake', 'Wake the screen', Icons.brightness_7_outlined, () => UsbLink.phoneKey(_serial, 'wake'), 'Woke the phone screen.', 'The phone screen stayed off.'),
            const SizedBox(width: 8),
            _navButton('volume-down', 'Volume down', Icons.remove_rounded, () => UsbLink.phoneKey(_serial, 'volumeDown'), 'Turned the volume down.', 'The phone did not change the volume.'),
            _navButton('volume-up', 'Volume up', Icons.add_rounded, () => UsbLink.phoneKey(_serial, 'volumeUp'), 'Turned the volume up.', 'The phone did not change the volume.'),
            IconButton(
              key: const ValueKey('phone-control-refresh'),
              tooltip: 'Update the picture',
              color: Colors.white,
              onPressed: widget.preview
                  ? null
                  : () async {
                      final ok = await _captureNow();
                      if (!mounted) return;
                      setState(() => _note = ok ? 'Updated the picture.' : 'The picture did not update.');
                    },
              icon: const Icon(Icons.photo_outlined),
            ),
          ],
        ),
      ),
    );
  }

  Widget _navButton(String key, String tip, IconData icon, Future<bool> Function() action, String ok, String fail) {
    return IconButton(
      key: ValueKey('phone-control-$key'),
      tooltip: tip,
      color: Colors.white,
      onPressed: () => _run(action, ok, fail),
      icon: Icon(icon),
    );
  }

  Widget _typeRow() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const ValueKey('phone-control-type'),
            controller: _type,
            textInputAction: TextInputAction.send,
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Type a sentence, then send',
              filled: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onSubmitted: (_) => unawaited(_sendType()),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          key: const ValueKey('phone-control-type-send'),
          onPressed: () => unawaited(_sendType()),
          child: const Text('Type'),
        ),
      ],
    );
  }

  Widget _appColumn(ThemeData theme, ColorScheme scheme) {
    final shown = [for (final app in _apps) if (phoneControlMatches(app, _search.text)) app];
    final yours = [for (final app in shown) if (!app.system) app];
    final system = [for (final app in shown) if (app.system) app];
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('Apps', style: theme.textTheme.titleMedium)),
                if (_appsReady && _named) Text('${shown.length}', style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
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
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search apps',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Expanded(child: _appList(theme, scheme, yours, system)),
          ],
        ),
      ),
    );
  }

  Widget _appList(ThemeData theme, ColorScheme scheme, List<PhoneControlApp> yours, List<PhoneControlApp> system) {
    if (!_appsReady) {
      return Text('Reading apps on the phone…', style: theme.textTheme.bodyMedium);
    }
    if (!_named) {
      return Text(
        'Update Social Save on the phone to see app names. You can still drag the screen, use Back, Home, and Recents, and type.',
        style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
      );
    }
    if (_apps.isEmpty) {
      return Text('This phone has no launchable apps Social Save can open.', style: theme.textTheme.bodyMedium);
    }
    if (yours.isEmpty && system.isEmpty) {
      return Text('No app matches that search.', style: theme.textTheme.bodyMedium);
    }
    final rows = <Widget>[];
    if (yours.isNotEmpty) {
      rows.add(_groupLabel(theme, scheme, 'On this phone'));
      for (final app in yours) {
        rows.add(_appTile(theme, scheme, app));
      }
    }
    if (system.isNotEmpty) {
      rows.add(_groupLabel(theme, scheme, 'System'));
      for (final app in system) {
        rows.add(_appTile(theme, scheme, app));
      }
    }
    return ListView(children: rows);
  }

  Widget _groupLabel(ThemeData theme, ColorScheme scheme, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 2),
      child: Text(label, style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700)),
    );
  }

  Widget _appTile(ThemeData theme, ColorScheme scheme, PhoneControlApp app) {
    final mark = String.fromCharCodes([app.name.runes.first]).toUpperCase();
    return ListTile(
      key: ValueKey('phone-control-app-${app.packageName}'),
      dense: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: app.system ? scheme.surfaceContainerHighest : scheme.primaryContainer,
        child: Text(mark, style: theme.textTheme.labelLarge),
      ),
      title: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        app.packageName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
      onTap: () => _run(
        () => UsbLink.openPhoneApp(_serial, app.packageName),
        'Opened ${app.name}.',
        'The phone did not open ${app.name}.',
      ),
    );
  }
}

class _FingerStroke extends CustomPainter {
  _FingerStroke(this.from, this.to);

  final Offset from;
  final Offset to;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = const Color(0xEEFFFFFF)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(from, to, line);
    canvas.drawCircle(to, 8, Paint()..color = const Color(0x66FFFFFF));
    canvas.drawCircle(to, 3.5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _FingerStroke oldDelegate) => oldDelegate.from != from || oldDelegate.to != to;
}
