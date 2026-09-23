import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/di/providers.dart';
import 'package:social_save/core/errors/exceptions.dart';
import 'package:social_save/core/utils/platform_detector.dart';
import 'package:social_save/core/utils/url_validator.dart';
import 'package:social_save/shared/models/media_info.dart';
import 'package:social_save/shared/models/social_platform.dart';

final homeControllerProvider =
    NotifierProvider<HomeController, HomeState>(HomeController.new);

class HomeState {
  const HomeState({
    this.url = '',
    this.clipboardUrl,
    this.isAnalyzing = false,
    this.error,
    this.lastResult,
  });

  final String url;
  final String? clipboardUrl;
  final bool isAnalyzing;
  final String? error;
  final MediaInfo? lastResult;

  bool get canPasteLink =>
      clipboardUrl != null && clipboardUrl!.isNotEmpty && clipboardUrl != url;

  SocialPlatform get detectedPlatform =>
      const PlatformDetector().detect(url);

  HomeState copyWith({
    String? url,
    String? clipboardUrl,
    bool? isAnalyzing,
    String? error,
    MediaInfo? lastResult,
    bool clearError = false,
    bool clearClipboard = false,
  }) {
    return HomeState(
      url: url ?? this.url,
      clipboardUrl: clearClipboard ? null : (clipboardUrl ?? this.clipboardUrl),
      isAnalyzing: isAnalyzing ?? this.isAnalyzing,
      error: clearError ? null : (error ?? this.error),
      lastResult: lastResult ?? this.lastResult,
    );
  }
}

class HomeController extends Notifier<HomeState> {
  final UrlValidator _validator = const UrlValidator();
  final PlatformDetector _detector = const PlatformDetector();
  static final _urlInText = RegExp(
    r'https?://[^\s<>"]+',
    caseSensitive: false,
  );

  String? _lastAutoImportedUrl;

  @override
  HomeState build() => const HomeState();

  void setUrl(String value) {
    state = state.copyWith(url: value, clearError: true);
  }

  Future<void> refreshClipboardOffer() async {
    final url = await _supportedClipboardUrl();
    if (url == null) {
      state = state.copyWith(clearClipboard: true);
      return;
    }
    state = state.copyWith(clipboardUrl: url);
  }

  Future<void> pasteFromClipboard() async {
    final url = await _supportedClipboardUrl();
    if (url == null) {
      state = state.copyWith(error: 'No supported video link is on the clipboard.');
      return;
    }
    state = state.copyWith(url: url, clipboardUrl: url, clearError: true);
  }

  Future<MediaInfo?> pasteAndAnalyze() async {
    final url = await _supportedClipboardUrl();
    if (url == null) {
      state = state.copyWith(error: 'No supported video link is on the clipboard.');
      return null;
    }
    state = state.copyWith(url: url, clipboardUrl: url, clearError: true);
    return analyze();
  }

  Future<String?> _supportedClipboardUrl() async {
    final url = await _readClipboardUrl();
    if (url == null || _detector.detect(url) == SocialPlatform.unknown) {
      return null;
    }
    return url;
  }

  /// Fills a supported public URL from the clipboard and analyzes it.
  Future<MediaInfo?> importClipboardAndAnalyze({bool auto = false}) async {
    if (state.isAnalyzing) return null;
    final url = await _readClipboardUrl();
    if (url == null) {
      if (!auto) {
        state = state.copyWith(error: 'No public video link found on the clipboard.');
      }
      return null;
    }
    if (_detector.detect(url) == SocialPlatform.unknown) {
      if (!auto) {
        state = state.copyWith(
          error:
              'That clipboard link is not a supported public video source.',
        );
      }
      return null;
    }
    if (auto && url == _lastAutoImportedUrl) {
      return null;
    }
    _lastAutoImportedUrl = url;
    state = state.copyWith(url: url, clipboardUrl: url, clearError: true);
    return analyze();
  }

  Future<String?> _readClipboardUrl() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return _extractPublicUrl(data?.text);
  }

  String? _extractPublicUrl(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final direct = _validator.validate(trimmed);
    if (direct.isValid) {
      return direct.normalized.toString();
    }
    final match = _urlInText.firstMatch(trimmed);
    if (match == null) return null;
    final found = _validator.validate(match.group(0)!);
    return found.isValid ? found.normalized.toString() : null;
  }

  void useSampleUrl() {
    state = state.copyWith(
      url: AppConstants.samplePublicVideoUrl,
      clearError: true,
    );
  }

  String? validatedUrl() {
    final validation = _validator.validate(state.url);
    if (!validation.isValid) {
      state = state.copyWith(error: validation.reason);
      return null;
    }
    state = state.copyWith(url: validation.normalized.toString(), clearError: true);
    return validation.normalized.toString();
  }

  Future<MediaInfo?> analyze() async {
    final validation = _validator.validate(state.url);
    if (!validation.isValid) {
      state = state.copyWith(error: validation.reason);
      return null;
    }
    state = state.copyWith(isAnalyzing: true, clearError: true);
    try {
      final result = await ref
          .read(mediaRepositoryProvider)
          .analyze(validation.normalized.toString());
      state = state.copyWith(isAnalyzing: false, lastResult: result);
      return result;
    } on AppException catch (error) {
      state = state.copyWith(isAnalyzing: false, error: error.message);
      return null;
    } catch (_) {
      state = state.copyWith(
        isAnalyzing: false,
        error: 'Unable to analyze this URL right now.',
      );
      return null;
    }
  }
}
