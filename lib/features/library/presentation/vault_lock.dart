import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/features/library/vault_service.dart';

// The Vault lock (PIN pad) and the providers it uses. Moved here from the
// classic Library screen in 1.0.123 when only one Library remained.

final vaultServiceProvider = Provider<VaultService>(
  (ref) => throw StateError('vaultServiceProvider must be overridden'),
);

final vaultUnlockedProvider = StateProvider<bool>((ref) => false);

class VaultLockPane extends ConsumerStatefulWidget {
  const VaultLockPane({super.key, this.onUnlocked, this.onCancel});

  final VoidCallback? onUnlocked;
  final VoidCallback? onCancel;

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
    _lockTick?.cancel();
    _shake.dispose();
    _focus.dispose();
    super.dispose();
  }

  Timer? _lockTick;

  /// Plain wait text, e.g. "30 seconds" or "5 minutes".
  static String waitLabel(Duration wait) {
    final s = wait.inSeconds + (wait.inMilliseconds % 1000 > 0 ? 1 : 0);
    if (s < 60) return '$s second${s == 1 ? '' : 's'}';
    final m = (s / 60).ceil();
    return '$m minute${m == 1 ? '' : 's'}';
  }

  /// Shows the wait after too many wrong PINs and counts it down.
  bool _showLock() {
    final vault = ref.read(vaultServiceProvider);
    final wait = vault.lockedFor();
    if (wait <= Duration.zero) {
      _lockTick?.cancel();
      _lockTick = null;
      return false;
    }
    setState(() {
      _pin = '';
      _error = 'Too many wrong tries. Try again in ${waitLabel(wait)}.';
    });
    _lockTick ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (!_showLock()) setState(() => _error = null);
    });
    return true;
  }

  void _wrong() {
    HapticFeedback.heavyImpact();
    HapticFeedback.vibrate();
    _shake.forward(from: 0);
  }

  Future<void> _press(String digit) async {
    if (_pin.length >= _length) return;
    final vault = ref.read(vaultServiceProvider);
    if (vault.hasPin && _showLock()) return;
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
    if (nav.canPop()) {
      nav.pop(false);
      return;
    }
    widget.onCancel?.call();
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
    final check = await vault.checkPin(pin);
    if (!mounted) return;
    if (check.ok) {
      ref.read(vaultUnlockedProvider.notifier).state = true;
      widget.onUnlocked?.call();
      return;
    }
    _wrong();
    if (check.wait > Duration.zero) {
      _showLock();
      return;
    }
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
    final scheme = Theme.of(context).colorScheme;
    final ink = scheme.onSurface;
    final muted = scheme.onSurface.withValues(alpha: 0.5);
    final vault = ref.watch(vaultServiceProvider);
    final creating = !vault.hasPin;
    final title = creating
        ? (_confirming ? 'Confirm PIN' : 'Create PIN')
        : 'Enter PIN';
    Widget row(List<String> keys, double s) => Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [for (final k in keys) _PinKey(digit: k, h: 80 * s, onTap: () => _press(k))],
    );
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: ColoredBox(
        color: scheme.surface,
        child: SafeArea(
          child: LayoutBuilder(builder: (context, c) { final s = (c.maxHeight / 700).clamp(0.7, 1.0).toDouble(); return Stack(
            children: [
              Center(
                child: FittedBox(fit: BoxFit.scaleDown, child: Column(mainAxisSize: MainAxisSize.min, children: [ Icon(Icons.lock_outline_rounded, size: 26, color: muted),
                      const SizedBox(height: 20),
                      Text(
                        title,
                        style: TextStyle(
                          color: ink,
                          fontSize: 20,
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(height: 30),
                      AnimatedBuilder(
                        animation: _shake,
                        builder: (context, child) {
                          final dx = math.sin(_shake.value * math.pi * 6) *
                              8 *
                              (1 - _shake.value);
                          return Transform.translate(offset: Offset(dx, 0), child: child);
                        },
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 0; i < _length; i++)
                              Semantics(
                                label: 'PIN digit ${i + 1}, ${i < _pin.length ? 'filled' : 'empty'}',
                                excludeSemantics: true,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 9),
                                  child: AnimatedScale(
                                    scale: i < _pin.length ? 1.0 : 0.88,
                                    duration: const Duration(milliseconds: 160),
                                    curve: Curves.easeOutBack,
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 160),
                                      width: 12,
                                      height: 12,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: i < _pin.length ? ink : Colors.transparent,
                                        border: Border.all(
                                          color: i < _pin.length
                                              ? ink
                                              : ink.withValues(alpha: 0.4),
                                          width: 1.2,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      SizedBox(
                        height: 40,
                        child: Center(
                          child: Text(
                            _error ?? '',
                            style: TextStyle(color: muted, fontSize: 12.5),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      row(['1', '2', '3'], s),
                      row(['4', '5', '6'], s),
                      row(['7', '8', '9'], s),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(width: 88, height: 80 * s),
                          _PinKey(digit: '0', h: 80 * s, onTap: () => _press('0')),
                          Semantics(
                            button: true,
                            label: 'Delete',
                            excludeSemantics: true,
                            child: SizedBox(
                              width: 88,
                              height: 80,
                              child: InkResponse(
                                radius: 36,
                                onTap: _backspace,
                                child: Icon(
                                  Icons.backspace_outlined,
                                  size: 22,
                                  color: _pin.isEmpty ? muted.withValues(alpha: 0.35) : muted,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ); }),
        ),
      ),
    );
  }
}

/// Plain light-weight digit with a soft circular press highlight.
class _PinKey extends StatelessWidget {
  const _PinKey({required this.digit, required this.onTap, required this.h});

  final double h;
  final String digit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Digit $digit',
      excludeSemantics: true,
      child: SizedBox(
        width: 88,
        height: h,
        child: InkResponse(
          onTap: onTap,
          radius: 40,
          highlightShape: BoxShape.circle,
          containedInkWell: false,
          highlightColor: scheme.onSurface.withValues(alpha: 0.08),
          splashColor: scheme.onSurface.withValues(alpha: 0.10),
          child: Center(
            child: Text(
              digit,
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 30,
                fontWeight: FontWeight.w300,
                height: 1,
              ),
            ),
          ),
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
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
    clipBehavior: Clip.antiAlias,
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
