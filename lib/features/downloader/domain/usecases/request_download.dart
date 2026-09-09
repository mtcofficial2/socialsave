import 'package:social_save/features/downloader/domain/repositories/media_repository.dart';
import 'package:social_save/shared/models/download_ticket.dart';

class RequestDownload {
  const RequestDownload(this._repository);

  final MediaRepository _repository;

  Future<DownloadTicket> call({
    required String url,
    required String formatId,
  }) {
    return _repository.requestDownload(url: url, formatId: formatId);
  }
}
