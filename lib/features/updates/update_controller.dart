import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/core/utils/open_link.dart';
import 'package:social_save/features/updates/release_version.dart';

const _releasesUrl =
    'https://api.github.com/repos/mtcofficial2/socialsave/releases/latest';

class UpdateState {
  const UpdateState({
    this.update,
    this.progress,
    this.message,
    this.busy = false,
  });

  final AvailableUpdate? update;
  final double? progress;
  final String? message;
  final bool busy;

  UpdateState copyWith({
    AvailableUpdate? update,
    double? progress,
    String? message,
    bool? busy,
    bool clearProgress = false,
    bool clearMessage = false,
  }) {
    return UpdateState(
      update: update ?? this.update,
      progress: clearProgress ? null : (progress ?? this.progress),
      message: clearMessage ? null : (message ?? this.message),
      busy: busy ?? this.busy,
    );
  }
}

final updateControllerProvider =
    NotifierProvider<UpdateController, UpdateState>(UpdateController.new);

class UpdateController extends Notifier<UpdateState> {
  DateTime? _lastLook;
  Future<void>? _flight;

  @override
  UpdateState build() => const UpdateState();

  /// Asks GitHub again while the app stays open. A failed look can be repeated.
  Future<void> check({bool force = false}) {
    if (!Plat.isAndroid) return Future<void>.value();
    if (state.busy) return Future<void>.value();
    final now = DateTime.now();
    if (!updateLookDue(last: _lastLook, now: now, force: force)) {
      return Future<void>.value();
    }
    final running = _flight;
    if (running != null) return running;
    _lastLook = now;
    final job = _look();
    _flight = job;
    return job.whenComplete(() {
      if (identical(_flight, job)) _flight = null;
    });
  }

  Future<void> _look() async {
    try {
      final current = AppConstants.appVersion;
      final response = await Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
          headers: const {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'SocialSave',
          },
        ),
      ).get<Map<String, dynamic>>(_releasesUrl);
      final data = response.data;
      if (data == null) return;
      final apk = androidReleaseApk(data['assets']);
      final update = newerRelease(
        current: current,
        tag: '${data['tag_name'] ?? ''}',
        apkUrl: apk,
      );
      if (update == null || !update.downloadUrl.path.toLowerCase().endsWith('.apk')) {
        if (state.update != null && !state.busy) state = const UpdateState();
        return;
      }
      if (state.update?.version == update.version &&
          state.update?.downloadUrl == update.downloadUrl) {
        return;
      }
      state = UpdateState(update: update);
    } on DioException catch (error) {
      final code = error.response?.statusCode;
      if (code == 403 || code == 429) {
        _lastLook = DateTime.now().add(const Duration(minutes: 9));
      }
    } catch (_) {
      // A failed check should not block the app. The next look tries again.
    }
  }

  /// Opens the latest GitHub app file. The release check already picked that
  /// file, so the phone downloads it and the person installs it.
  Future<void> downloadAndInstall() async {
    final update = state.update;
    if (update == null || state.busy) return;
    state = state.copyWith(busy: true, clearProgress: true, clearMessage: true);
    try {
      final opened = await openWebLink(update.downloadUrl.toString());
      state = state.copyWith(
        busy: false,
        message: opened
            ? 'The latest app is downloading. Install it when the file finishes.'
            : 'Could not open the download. Try again.',
      );
    } catch (_) {
      state = state.copyWith(
        busy: false,
        message: 'Could not open the download. Try again.',
      );
    }
  }
}
