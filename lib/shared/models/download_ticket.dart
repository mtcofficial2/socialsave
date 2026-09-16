import 'package:equatable/equatable.dart';

enum DownloadJobState { ready, processing, failed }

class DownloadTicket extends Equatable {
  const DownloadTicket({
    required this.downloadUrl,
    this.jobId,
    this.expiresAt,
    this.state = DownloadJobState.ready,
    this.mimeType,
    this.filesize,
    this.fileName,
    this.directUrl,
    this.requestHeaders,
  });

  final String downloadUrl;
  final String? jobId;
  final DateTime? expiresAt;
  final DownloadJobState state;
  final String? mimeType;
  final int? filesize;
  final String? fileName;
  final String? directUrl;
  final Map<String, String>? requestHeaders;

  bool get isReady =>
      state == DownloadJobState.ready && downloadUrl.isNotEmpty;

  factory DownloadTicket.fromJson(Map<String, dynamic> json) {
    final stateName = json['state'] as String? ?? 'ready';
    return DownloadTicket(
      downloadUrl: json['download_url'] as String? ?? '',
      jobId: json['id'] as String? ?? json['job_id'] as String?,
      expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? ''),
      state: DownloadJobState.values.firstWhere(
        (value) => value.name == stateName,
        orElse: () => DownloadJobState.ready,
      ),
      mimeType: json['mime_type'] as String?,
      filesize: json['filesize'] is int ? json['filesize'] as int : null,
      fileName: json['file_name'] as String?,
      directUrl: json['direct_url'] as String?,
      requestHeaders: _stringMap(json['request_headers'] ?? json['headers']),
    );
  }

  static Map<String, String>? _stringMap(Object? raw) {
    if (raw is! Map) return null;
    final out = <String, String>{};
    raw.forEach((key, value) {
      if (key is String && value != null) {
        out[key] = value.toString();
      }
    });
    return out.isEmpty ? null : out;
  }

  @override
  List<Object?> get props =>
      [downloadUrl, jobId, expiresAt, state, mimeType, filesize, fileName, directUrl];
}

class DownloadJobStatus extends Equatable {
  const DownloadJobStatus({
    required this.id,
    required this.state,
    this.downloadUrl,
    this.errorCode,
    this.errorMessage,
    this.progress,
    this.filesize,
  });

  final String id;
  final DownloadJobState state;
  final String? downloadUrl;
  final String? errorCode;
  final String? errorMessage;
  final double? progress;
  final int? filesize;

  factory DownloadJobStatus.fromJson(Map<String, dynamic> json) {
    final stateName = json['state'] as String? ?? json['status'] as String? ?? 'processing';
    return DownloadJobStatus(
      id: json['id'] as String? ?? '',
      state: DownloadJobState.values.firstWhere(
        (value) => value.name == stateName,
        orElse: () => DownloadJobState.processing,
      ),
      downloadUrl: json['download_url'] as String?,
      errorCode: json['error_code'] as String?,
      errorMessage: json['error_message'] as String? ??
          (json['error'] is Map ? (json['error'] as Map)['message'] as String? : null),
      progress: (json['progress'] as num?)?.toDouble(),
      filesize: json['filesize'] is int ? json['filesize'] as int : null,
    );
  }

  @override
  List<Object?> get props =>
      [id, state, downloadUrl, errorCode, errorMessage, progress, filesize];
}
