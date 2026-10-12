import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:social_save/core/network/windows_dns_fallback.dart';

enum NetworkAccess { offline, wifi, cellular, other }

class ConnectivityService {
  ConnectivityService({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  Future<NetworkAccess> current() async {
    final results = await _connectivity.checkConnectivity();
    final access = fromResults(results);
    // Windows can report "none" behind VPN adapters (Surfshark, VeePN) while
    // the internet works. Confirm with a quick DNS lookup before giving up.
    if (access == NetworkAccess.offline && Platform.isWindows) {
      try {
        final found = await WindowsDnsFallback.resolve(
          'socialsave-api-p2tm.onrender.com',
        ).timeout(const Duration(seconds: 15));
        if (found.isNotEmpty) return NetworkAccess.other;
      } catch (_) {}
    }
    return access;
  }

  Stream<NetworkAccess> get onChange async* {
    await for (final results in _connectivity.onConnectivityChanged) {
      final access = fromResults(results);
      yield access == NetworkAccess.offline && Platform.isWindows
          ? await current()
          : access;
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
