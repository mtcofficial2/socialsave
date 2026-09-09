import 'package:social_save/features/downloader/domain/repositories/media_repository.dart';
import 'package:social_save/shared/models/media_info.dart';

class AnalyzeUrl {
  const AnalyzeUrl(this._repository);

  final MediaRepository _repository;

  Future<MediaInfo> call(String url) => _repository.analyze(url);
}
