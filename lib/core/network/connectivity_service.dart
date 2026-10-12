import 'package:connectivity_plus/connectivity_plus.dart';

enum NetworkAccess { offline, wifi, cellular, other }

class ConnectivityService {
  ConnectivityService({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  Future<NetworkAccess> current() async {
    final results = await _connectivity.checkConnectivity();
    final access = fromResults(results);
    // The system often says "none" while the internet works (VPNs, some
    // phones, captive DNS). Never block on that guess: report "unknown" and
    // let the real request decide; it shows a clear error if it fails.
    if (access == NetworkAccess.offline) return NetworkAccess.other;
    return access;
  }

  Stream<NetworkAccess> get onChange async* {
    await for (final results in _connectivity.onConnectivityChanged) {
      final access = fromResults(results);
      yield access == NetworkAccess.offline ? NetworkAccess.other : access;
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
