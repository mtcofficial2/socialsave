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
    this.isAnalyzing = false,
    this.error,
    this.lastResult,
  });

  final String url;
  final bool isAnalyzing;
  final String? error;
  final MediaInfo? lastResult;

  SocialPlatform get detectedPlatform =>
      const PlatformDetector().detect(url);

  HomeState copyWith({
    String? url,
    bool? isAnalyzing,
    String? error,
    MediaInfo? lastResult,
    bool clearError = false,
  }) {
    return HomeState(
      url: url ?? this.url,
      isAnalyzing: isAnalyzing ?? this.isAnalyzing,
      error: clearError ? null : (error ?? this.error),
      lastResult: lastResult ?? this.lastResult,
    );
  }
}

class HomeController extends Notifier<HomeState> {
  final UrlValidator _validator = const UrlValidator();

  @override
  HomeState build() => const HomeState();

  void setUrl(String value) {
    state = state.copyWith(url: value, clearError: true);
  }

  Future<void> pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      state = state.copyWith(error: 'Clipboard is empty.');
      return;
    }
    state = state.copyWith(url: text, clearError: true);
  }

  void useSampleUrl() {
    state = state.copyWith(
      url: AppConstants.samplePublicVideoUrl,
      clearError: true,
    );
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
