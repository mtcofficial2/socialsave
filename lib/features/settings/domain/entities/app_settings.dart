import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:social_save/core/storage/download_path_service.dart';

enum VideoQualityPreference { auto, p360, p480, p720, p1080, p1440, p2160, original }

enum VideoFormatPreference { mp4, webm, original }

class AppSettings extends Equatable {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.downloadLocation = DownloadLocation.appStorage,
    this.wifiOnly = true,
    this.autoStartDownloads = true,
    this.notificationsEnabled = true,
    this.defaultQuality = VideoQualityPreference.original,
    this.defaultFormat = VideoFormatPreference.mp4,
  });

  final ThemeMode themeMode;
  final DownloadLocation downloadLocation;
  final bool wifiOnly;
  final bool autoStartDownloads;
  final bool notificationsEnabled;
  final VideoQualityPreference defaultQuality;
  final VideoFormatPreference defaultFormat;

  AppSettings copyWith({
    ThemeMode? themeMode,
    DownloadLocation? downloadLocation,
    bool? wifiOnly,
    bool? autoStartDownloads,
    bool? notificationsEnabled,
    VideoQualityPreference? defaultQuality,
    VideoFormatPreference? defaultFormat,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      downloadLocation: downloadLocation ?? this.downloadLocation,
      wifiOnly: wifiOnly ?? this.wifiOnly,
      autoStartDownloads: autoStartDownloads ?? this.autoStartDownloads,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      defaultQuality: defaultQuality ?? this.defaultQuality,
      defaultFormat: defaultFormat ?? this.defaultFormat,
    );
  }

  String get qualityLabel => defaultQuality.label;
  String get formatLabel => defaultFormat.label;

  Map<String, Object> toMap() {
    return {
      'themeMode': themeMode.name,
      'downloadLocation': downloadLocation.name,
      'wifiOnly': wifiOnly,
      'autoStartDownloads': autoStartDownloads,
      'notificationsEnabled': notificationsEnabled,
      'defaultQuality': defaultQuality.name,
      'defaultFormat': defaultFormat.name,
    };
  }

  factory AppSettings.fromMap(Map<String, Object?> map) {
    return AppSettings(
      themeMode: ThemeMode.values.firstWhere(
        (value) => value.name == map['themeMode'],
        orElse: () => ThemeMode.system,
      ),
      downloadLocation: DownloadLocation.values.firstWhere(
        (value) => value.name == map['downloadLocation'],
        orElse: () => DownloadLocation.appStorage,
      ),
      wifiOnly: map['wifiOnly'] as bool? ?? true,
      autoStartDownloads: map['autoStartDownloads'] as bool? ?? true,
      notificationsEnabled: map['notificationsEnabled'] as bool? ?? true,
      defaultQuality: VideoQualityPreference.values.firstWhere(
        (value) => value.name == map['defaultQuality'],
        orElse: () => VideoQualityPreference.auto,
      ),
      defaultFormat: VideoFormatPreference.values.firstWhere(
        (value) => value.name == map['defaultFormat'],
        orElse: () => VideoFormatPreference.mp4,
      ),
    );
  }

  @override
  List<Object?> get props => [
        themeMode,
        downloadLocation,
        wifiOnly,
        autoStartDownloads,
        notificationsEnabled,
        defaultQuality,
        defaultFormat,
      ];
}

extension VideoQualityPreferenceX on VideoQualityPreference {
  String get label {
    switch (this) {
      case VideoQualityPreference.auto:
        return 'Auto';
      case VideoQualityPreference.p360:
        return '360p';
      case VideoQualityPreference.p480:
        return '480p';
      case VideoQualityPreference.p720:
        return '720p';
      case VideoQualityPreference.p1080:
        return '1080p';
      case VideoQualityPreference.p1440:
        return '1440p';
      case VideoQualityPreference.p2160:
        return '2160p';
      case VideoQualityPreference.original:
        return 'Original';
    }
  }

  String get apiValue {
    switch (this) {
      case VideoQualityPreference.auto:
        return 'auto';
      case VideoQualityPreference.p360:
        return '360p';
      case VideoQualityPreference.p480:
        return '480p';
      case VideoQualityPreference.p720:
        return '720p';
      case VideoQualityPreference.p1080:
        return '1080p';
      case VideoQualityPreference.p1440:
        return '1440p';
      case VideoQualityPreference.p2160:
        return '2160p';
      case VideoQualityPreference.original:
        return 'original';
    }
  }
}

extension VideoFormatPreferenceX on VideoFormatPreference {
  String get label {
    switch (this) {
      case VideoFormatPreference.mp4:
        return 'MP4';
      case VideoFormatPreference.webm:
        return 'WebM';
      case VideoFormatPreference.original:
        return 'Original';
    }
  }

  String get apiValue {
    switch (this) {
      case VideoFormatPreference.mp4:
        return 'mp4';
      case VideoFormatPreference.webm:
        return 'webm';
      case VideoFormatPreference.original:
        return 'original';
    }
  }
}
