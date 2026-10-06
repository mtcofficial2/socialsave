enum DownloadStatus {
  queued,
  running,
  paused,
  waitingWifi,
  waitingPower,
  completed,
  failed,
  cancelled;

  bool get isActive =>
      this == DownloadStatus.queued ||
      this == DownloadStatus.running ||
      this == DownloadStatus.paused ||
      this == DownloadStatus.waitingWifi ||
      this == DownloadStatus.waitingPower;

  bool get canPause => this == DownloadStatus.running;
  bool get canResume =>
      this == DownloadStatus.paused ||
      this == DownloadStatus.waitingWifi ||
      this == DownloadStatus.waitingPower;
  bool get canRetry =>
      this == DownloadStatus.failed || this == DownloadStatus.cancelled;
  bool get canCancel =>
      this == DownloadStatus.queued ||
      this == DownloadStatus.running ||
      this == DownloadStatus.paused ||
      this == DownloadStatus.waitingWifi ||
      this == DownloadStatus.waitingPower;

  String get label {
    switch (this) {
      case DownloadStatus.queued:
        return 'Queued';
      case DownloadStatus.running:
        return 'Downloading';
      case DownloadStatus.paused:
        return 'Paused';
      case DownloadStatus.waitingWifi:
        return 'Waiting for Wi-Fi';
      case DownloadStatus.waitingPower:
        return 'Waiting for the phone';
      case DownloadStatus.completed:
        return 'Saved';
      case DownloadStatus.failed:
        return 'Failed';
      case DownloadStatus.cancelled:
        return 'Cancelled';
    }
  }

  static DownloadStatus fromName(String? value) {
    return DownloadStatus.values.firstWhere(
      (item) => item.name == value,
      orElse: () => DownloadStatus.failed,
    );
  }
}
