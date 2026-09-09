import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/features/downloads/data/datasources/download_history_store.dart';
import 'package:social_save/features/downloads/domain/entities/download_record.dart';
import 'package:social_save/shared/models/download_status.dart';
import 'package:social_save/shared/models/social_platform.dart';

void main() {
  test('upserts, lists, and deletes records', () async {
    final store = InMemoryDownloadHistoryStore();
    final record = DownloadRecord(
      id: '1',
      title: 'Demo',
      sourceUrl: 'https://example.com/a.mp4',
      platform: SocialPlatform.direct,
      downloadedAt: DateTime(2026, 1, 1),
      status: DownloadStatus.completed,
      fileSize: 12,
    );
    await store.upsert(record);
    expect((await store.getAll()).single.id, '1');
    await store.delete('1');
    expect(await store.getAll(), isEmpty);
  });
}
