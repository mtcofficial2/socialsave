import 'dart:io';

import 'package:flutter/material.dart';
import 'package:social_save/features/library/device_media.dart';

class LocalVideoThumb extends StatefulWidget {
  const LocalVideoThumb({
    super.key,
    required this.cacheKey,
    this.id,
    this.path,
    this.uri,
    this.borderRadius = 16,
  });

  final String cacheKey;
  final String? id;
  final String? path;
  final String? uri;
  final double borderRadius;

  @override
  State<LocalVideoThumb> createState() => _LocalVideoThumbState();
}

class _LocalVideoThumbState extends State<LocalVideoThumb> {
  static final _memory = <String, String?>{};
  String? _file;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(LocalVideoThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheKey != widget.cacheKey) {
      _load();
    }
  }

  Future<void> _load() async {
    final cached = _memory[widget.cacheKey];
    if (cached != null && File(cached).existsSync()) {
      setState(() {
        _file = cached;
        _loading = false;
      });
      return;
    }
    final key = widget.cacheKey;
    setState(() {
      _loading = true;
      _file = null;
    });
    final path = await DeviceMediaService().videoThumbnail(
      id: widget.id,
      path: widget.path,
      uri: widget.uri,
    );
    _memory[key] = path;
    if (!mounted || widget.cacheKey != key) return;
    setState(() {
      _file = path;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final file = _file;
    return SizedBox.expand(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: ColoredBox(
          color: scheme.surfaceContainerHigh,
          child: file != null && File(file).existsSync()
              ? Image.file(
                  File(file),
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                )
              : Center(
                  child: _loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.videocam_outlined, color: scheme.outline),
                ),
        ),
      ),
    );
  }
}
