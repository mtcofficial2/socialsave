import 'package:connectivity_plus/connectivity_plus.dart';

enum NetworkAccess { offline, wifi, cellular, other }

class ConnectivityService {
  ConnectivityService({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  Future<NetworkAccess> current() async {
    final results = await _connectivity.checkConnectivity();
    return fromResults(results);
  }

  Stream<NetworkAccess> get onChange async* {
    await for (final results in _connectivity.onConnectivityChanged) {
      yield fromResults(results);
    }
  }

  NetworkAccess fromResults(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.none) && results.length == 1) {
      return NetworkAccess.offline;
    }
    if (results.contains(ConnectivityResult.wifi)) {
      return NetworkAccess.wifi;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return NetworkAccess.cellular;
    }
    if (results.contains(ConnectivityResult.ethernet) ||
        results.contains(ConnectivityResult.vpn) ||
        results.contains(ConnectivityResult.other)) {
      return NetworkAccess.other;
    }
    return NetworkAccess.offline;
  }

  bool canDownload({
    required NetworkAccess access,
    required bool wifiOnly,
  }) {
    if (access == NetworkAccess.offline) {
      return false;
    }
    if (wifiOnly && access == NetworkAccess.cellular) {
      return false;
    }
    return true;
  }
}
