import 'package:social_save/features/downloads/data/datasources/download_history_store.dart';

/// Hive-backed history store. Kept as an alias so the data layer matches the
/// clean-architecture folder layout.
typedef DownloadsRepositoryImpl = HiveDownloadHistoryStore;
