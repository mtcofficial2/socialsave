import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:social_save/core/platform/media_events.dart';

/// QR scanner that opens a lens the phone really has.
///
/// mobile_scanner always asks for the back camera. Phones that expose only a
/// front camera to apps (the SHARP AQUOS R7 here) then failed with
/// "No cameras available" even with the permission granted.
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

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    var facings = const <String>[];
    try {
      facings = await MediaEvents.channel.invokeListMethod<String>('cameraFacings') ?? const [];
    } catch (_) {}
    if (!mounted) return;
    if (facings.isEmpty) {
      // Unknown (older build) → let the plugin try its default.
      facings = const ['back'];
    }
    final facing = facings.contains('back')
        ? CameraFacing.back
        : facings.contains('front')
            ? CameraFacing.front
            : facings.contains('external')
                ? CameraFacing.external
                : CameraFacing.back;
    setState(() {
      _facings = facings;
      _controller = MobileScannerController(facing: facing, formats: const [BarcodeFormat.qrCode]);
    });
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
          if (_facings.contains('back') && _facings.contains('front'))
            Positioned(
              right: 8,
              bottom: 8,
              child: IconButton.filledTonal(
                tooltip: 'Switch camera',
                onPressed: () => controller.switchCamera(),
                icon: const Icon(Icons.cameraswitch_rounded),
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
    return SizedBox(
      height: widget.height,
      child: ClipRRect(borderRadius: BorderRadius.circular(16), child: child),
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
