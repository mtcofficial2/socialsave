import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/platform/media_events.dart';

const _facingPref = 'socialsave_qr_camera_facing';

/// QR scanner that opens a lens the phone really has, with a Front / Rear
/// choice (remembered) when the phone has both.
class QrScanner extends StatefulWidget {
  const QrScanner({super.key, required this.onCode, this.height = 220});

  /// Called once per detected QR value.
  final ValueChanged<String> onCode;
  final double height;

  @override
  State<QrScanner> createState() => _QrScannerState();
}

class _QrScannerState extends State<QrScanner> {
  MobileScannerController? _controller;
  List<String> _facings = const [];
  CameraFacing _facing = CameraFacing.back;

  @override
  void initState() {
    super.initState();
    _init();
  }

  CameraFacing _pick(String? saved, List<String> facings) {
    if (saved == 'front' && facings.contains('front')) return CameraFacing.front;
    if (saved == 'back' && facings.contains('back')) return CameraFacing.back;
    return facings.contains('back')
        ? CameraFacing.back
        : facings.contains('front')
            ? CameraFacing.front
            : facings.contains('external')
                ? CameraFacing.external
                : CameraFacing.back;
  }

  Future<void> _init() async {
    var facings = const <String>[];
    try {
      facings = await MediaEvents.channel.invokeListMethod<String>('cameraFacings') ?? const [];
    } catch (_) {}
    String? saved;
    try {
      saved = (await SharedPreferences.getInstance()).getString(_facingPref);
    } catch (_) {}
    if (!mounted) return;
    if (facings.isEmpty) {
      // Unknown (older build): let the plugin try its default.
      facings = const ['back'];
    }
    final facing = _pick(saved, facings);
    setState(() {
      _facings = facings;
      _facing = facing;
      _controller = MobileScannerController(facing: facing, formats: const [BarcodeFormat.qrCode]);
    });
  }

  Future<void> _choose(CameraFacing facing) async {
    if (facing == _facing || !mounted) return;
    final old = _controller;
    setState(() {
      _facing = facing;
      _controller = null;
    });
    await old?.dispose();
    try {
      await (await SharedPreferences.getInstance()).setString(_facingPref, facing == CameraFacing.front ? 'front' : 'back');
    } catch (_) {}
    if (!mounted) return;
    setState(() => _controller = MobileScannerController(facing: facing, formats: const [BarcodeFormat.qrCode]));
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final controller = _controller;
    final both = _facings.contains('back') && _facings.contains('front');
    Widget child;
    if (controller == null) {
      child = const Center(child: CircularProgressIndicator());
    } else {
      child = Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: controller,
            onDetect: (capture) {
              for (final b in capture.barcodes) {
                final v = b.rawValue;
                if (v != null && v.isNotEmpty) {
                  widget.onCode(v);
                  return;
                }
              }
            },
            errorBuilder: (context, error) => _message(
              context,
              error.errorCode == MobileScannerErrorCode.permissionDenied
                  ? 'Allow camera access in Settings to scan, or type the code below.'
                  : 'The camera could not start (${error.errorCode.name}). Type the code below instead.',
            ),
          ),
          if (!_facings.contains('back') && _facings.contains('front'))
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Text(
                'Using the front camera: hold the other screen facing you.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, shadows: [Shadow(color: scheme.shadow, blurRadius: 4)]),
              ),
            ),
        ],
      );
    }
    final box = SizedBox(
      height: widget.height,
      child: ClipRRect(borderRadius: BorderRadius.circular(16), child: child),
    );
    if (!both) return box;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        box,
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Semantics(
                label: 'Choose camera: front or rear',
                container: true,
                child: SegmentedButton<CameraFacing>(
                  key: const ValueKey('qr-camera-choice'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: CameraFacing.back, icon: Icon(Icons.photo_camera_back_rounded), label: Text('Rear')),
                    ButtonSegment(value: CameraFacing.front, icon: Icon(Icons.photo_camera_front_rounded), label: Text('Front')),
                  ],
                  selected: {_facing},
                  onSelectionChanged: (s) => _choose(s.first),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              key: const ValueKey('qr-camera-flip'),
              tooltip: 'Flip camera',
              onPressed: () => _choose(_facing == CameraFacing.back ? CameraFacing.front : CameraFacing.back),
              icon: const Icon(Icons.cameraswitch_rounded),
            ),
          ],
        ),
      ],
    );
  }

  Widget _message(BuildContext context, String text) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.no_photography_rounded, color: scheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Flexible(child: Text(text, style: TextStyle(color: scheme.onSurfaceVariant))),
            ],
          ),
        ),
      ),
    );
  }
}