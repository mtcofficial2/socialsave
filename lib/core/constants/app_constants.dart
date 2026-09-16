class AppConstants {
  const AppConstants._();

  static const String appName = 'SocialSave';
  static const String appTagline = 'Paste a public video link and save it to this device';
  static const String appVersion = '1.0.0';

  static const String downloadsBoxName = 'downloads';
  static const String settingsPrefsPrefix = 'socialsave_';

  static const String defaultFolderName = 'SocialSave';
  static const String samplePublicVideoUrl =
      'https://interactive-examples.mdn.mozilla.net/media/cc0-videos/flower.mp4';

  static const Duration snackBarDuration = Duration(seconds: 4);
  static const Duration bannerDuration = Duration(seconds: 5);
  static const Duration speedSampleWindow = Duration(milliseconds: 400);

  static const int historyPreviewLimit = 8;
  static const int maxUrlLength = 2048;

  static const List<String> allowedVideoExtensions = [
    'mp4',
    'webm',
    'mov',
    'm4v',
    'mkv',
  ];

  static const List<String> allowedVideoMimeTypes = [
    'video/mp4',
    'video/webm',
    'video/quicktime',
    'video/x-m4v',
    'video/x-matroska',
    'video/mpeg',
  ];
}
