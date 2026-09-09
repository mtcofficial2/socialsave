import 'package:social_save/core/errors/exceptions.dart';

class ErrorMessages {
  const ErrorMessages._();

  static const String generic =
      'Something went wrong. Please try again in a moment.';

  static const String invalidUrl =
      'That does not look like a valid video link. Paste a full https URL.';

  static const String unsupportedPlatform =
      'This platform is not supported, or it has been disabled in this build.';

  static const String privateVideo =
      'Unable to access this video. Make sure the link is public and that downloading is permitted for this content.';

  static const String removedVideo =
      'This video is no longer available.';

  static const String platformUnavailable =
      'The source platform is temporarily unavailable. Try again later.';

  static const String platformDisabled =
      'This platform is turned off in the current configuration.';

  static const String downloadNotPermitted =
      'This platform does not allow third-party apps to download the file. SocialSave will not bypass that restriction.';

  static const String networkUnavailable =
      'You appear to be offline. Connect to the internet and try again.';

  static const String serverError =
      'The server could not complete this request. Please try again.';

  static const String timeout =
      'The request took too long. Check your connection and try again.';

  static const String downloadInterrupted =
      'The download was interrupted. You can retry from the Downloads tab.';

  static const String insufficientStorage =
      'There is not enough storage on this device to save the video.';

  static const String permissionDenied =
      'Storage or notification permission was denied. You can enable it in Settings.';

  static const String unsupportedFormat =
      'This file type is not a supported video format.';

  static const String fileTooLarge =
      'This file exceeds the maximum download size allowed by the app.';

  static const String unauthorized =
      'The app is not authorized to talk to the backend. Check API configuration.';

  static const String rateLimited =
      'Too many requests. Please wait a moment and try again.';

  static const String wifiOnly =
      'Wi-Fi only downloads are enabled. Connect to Wi-Fi to continue.';

  static String forCode(AppErrorCode code) {
    switch (code) {
      case AppErrorCode.invalidUrl:
        return invalidUrl;
      case AppErrorCode.unsupportedPlatform:
        return unsupportedPlatform;
      case AppErrorCode.privateVideo:
        return privateVideo;
      case AppErrorCode.removedVideo:
        return removedVideo;
      case AppErrorCode.platformUnavailable:
        return platformUnavailable;
      case AppErrorCode.platformDisabled:
        return platformDisabled;
      case AppErrorCode.downloadNotPermitted:
        return downloadNotPermitted;
      case AppErrorCode.networkUnavailable:
        return networkUnavailable;
      case AppErrorCode.serverError:
        return serverError;
      case AppErrorCode.timeout:
        return timeout;
      case AppErrorCode.downloadInterrupted:
        return downloadInterrupted;
      case AppErrorCode.insufficientStorage:
        return insufficientStorage;
      case AppErrorCode.permissionDenied:
        return permissionDenied;
      case AppErrorCode.unsupportedFormat:
        return unsupportedFormat;
      case AppErrorCode.fileTooLarge:
        return fileTooLarge;
      case AppErrorCode.unauthorized:
        return unauthorized;
      case AppErrorCode.rateLimited:
        return rateLimited;
      case AppErrorCode.unknown:
        return generic;
    }
  }
}
