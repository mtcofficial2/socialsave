import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/features/settings/domain/entities/app_settings.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';
import 'package:social_save/shared/models/media_format.dart';
import 'package:social_save/shared/models/media_info.dart';

final previewControllerProvider = NotifierProvider.family<PreviewController,
    PreviewState, MediaInfo>(PreviewController.new);

class PreviewState {
  const PreviewState({
    required this.media,
    this.selectedFormat,
    this.isStarting = false,
    this.error,
  });

  final MediaInfo media;
  final MediaFormat? selectedFormat;
  final bool isStarting;
  final String? error;

  MediaFormat? get format => selectedFormat ?? media.defaultFormat;

  PreviewState copyWith({
    MediaFormat? selectedFormat,
    bool? isStarting,
    String? error,
    bool clearError = false,
  }) {
    return PreviewState(
      media: media,
      selectedFormat: selectedFormat ?? this.selectedFormat,
      isStarting: isStarting ?? this.isStarting,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class PreviewController extends FamilyNotifier<PreviewState, MediaInfo> {
  @override
  PreviewState build(MediaInfo arg) {
    final settings = ref.read(settingsControllerProvider);
    return PreviewState(
      media: arg,
      selectedFormat: _pickDefault(arg, settings),
    );
  }

  void selectFormat(MediaFormat format) {
    state = state.copyWith(selectedFormat: format, clearError: true);
  }

  MediaFormat? _pickDefault(MediaInfo media, AppSettings settings) {
    if (media.formats.isEmpty) {
      return null;
    }
    final preferredQuality = settings.defaultQuality.apiValue;
    final preferredFormat = settings.defaultFormat.apiValue;

    MediaFormat? match({String? quality, String? format}) {
      for (final item in media.formats) {
        final qualityOk =
            quality == null || item.quality.toLowerCase() == quality;
        final formatOk = format == null ||
            format == 'original' ||
            item.format.toLowerCase() == format;
        if (qualityOk && formatOk) {
          return item;
        }
      }
      return null;
    }

    if (preferredQuality == 'auto' || preferredQuality == 'original') {
      return match(quality: 'original') ?? media.defaultFormat;
    }
    return match(quality: preferredQuality, format: preferredFormat) ??
        match(quality: preferredQuality) ??
        media.defaultFormat;
  }
}
