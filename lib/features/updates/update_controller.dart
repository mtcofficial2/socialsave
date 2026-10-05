import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/platform/media_events.dart';
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
  var _checked = false;

  @override
  UpdateState build() => const UpdateState();

  Future<void> check() async {
    if (_checked) return;
    _checked = true;
    try {
      final current = AppConstants.appVersion;
      final response = await Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
          headers: const {'Accept': 'application/vnd.github+json'},
        ),
      ).get<Map<String, dynamic>>(_releasesUrl);
      final data = response.data;
      if (data == null) return;
      final assets = data['assets'];
      String? apk;
      if (assets is List) {
        for (final asset in assets) {
          if (asset is Map && asset['name'] == 'SocialSave.apk') {
            apk = asset['browser_download_url'] as String?;
          }
        }
      }
      final update = newerRelease(
        current: current,
        tag: '${data['tag_name'] ?? ''}',
        apkUrl: apk,
      );
      if (update == null || !update.downloadUrl.path.toLowerCase().endsWith('.apk')) {
        return;
      }
      state = UpdateState(update: update);
    } catch (_) {
      // A failed check should not block the app.
    }
  }

  Future<void> downloadAndInstall() async {
    final update = state.update;
    if (update == null || state.busy) return;
    state = state.copyWith(busy: true, progress: 0, clearMessage: true);
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}SocialSave.apk');
      if (await file.exists()) {
        await file.delete();
      }
      await Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(minutes: 10),
        ),
      ).download(
        update.downloadUrl.toString(),
        file.path,
        onReceiveProgress: (received, total) {
          if (total <= 0) return;
          state = state.copyWith(progress: received / total, busy: true);
        },
      );
      final opened = await MediaEvents.channel.invokeMethod<bool>('installApk', {
        'path': file.path,
      });
      state = state.copyWith(
        busy: false,
        clearProgress: true,
        message: opened == true
            ? 'Confirm the install on the next screen.'
            : 'Allow SocialSave to install updates, then tap Update again.',
      );
    } catch (_) {
      state = state.copyWith(
        busy: false,
        clearProgress: true,
        message: 'Could not download the update inside the app.',
      );
    }
  }
}
