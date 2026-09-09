import 'package:social_save/features/downloads/domain/entities/download_record.dart';

abstract class DownloadsRepository {
  Future<List<DownloadRecord>> getAll();

  Future<DownloadRecord?> getById(String id);

  Future<void> upsert(DownloadRecord record);

  Future<void> delete(String id, {bool deleteFile = false});

  Future<void> clear({bool deleteFiles = false});

  Stream<List<DownloadRecord>> watch();
}
