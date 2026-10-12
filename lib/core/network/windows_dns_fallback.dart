import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Windows only. Some routers' DNS (this PC uses 192.168.100.1) refuses to
/// resolve hosts like `*.onrender.com`, so every request fails with
/// "offline". When the system lookup fails we ask Cloudflare / Google
/// DNS-over-HTTPS (reached by IP) and connect straight to that address,
/// keeping the real host name for TLS so certificates are still checked.
class WindowsDnsFallback {
  WindowsDnsFallback._();

  static final Map<String, List<InternetAddress>> _cache = {};

  static void install() {
    // Android too: some ISPs, routers and VPNs block *.onrender.com in DNS.
    if (!Platform.isWindows && !Platform.isAndroid) return;
    HttpOverrides.global = _FallbackOverrides();
  }

  /// System lookup first, DNS-over-HTTPS second. Throws when both fail.
  static Future<List<InternetAddress>> resolve(String host) async {
    if (InternetAddress.tryParse(host) != null) {
      return [InternetAddress(host)];
    }
    try {
      final found = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 4));
      if (found.isNotEmpty) return found;
    } catch (_) {}
    final cached = _cache[host];
    if (cached != null && cached.isNotEmpty) return cached;
    for (final server in const ['1.1.1.1', '8.8.8.8', '1.0.0.1']) {
      try {
        final ips = await _doh(server, host);
        if (ips.isNotEmpty) {
          _cache[host] = ips;
          return ips;
        }
      } catch (_) {}
    }
    throw SocketException('Could not resolve $host');
  }

  static Future<List<InternetAddress>> _doh(String server, String host) async {
    // Plain HttpClient without the override, so this never recurses.
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final path = server.startsWith('8.') ? '/resolve' : '/dns-query';
      final req = await client.getUrl(
        Uri.https(server, path, {'name': host, 'type': 'A'}),
      );
      req.headers.set('accept', 'application/dns-json');
      final res = await req.close().timeout(const Duration(seconds: 6));
      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final answers = (json['Answer'] as List?) ?? const [];
      return [
        for (final a in answers)
          if (a is Map && a['type'] == 1 && a['data'] is String)
            InternetAddress(a['data'] as String),
      ];
    } finally {
      client.close(force: true);
    }
  }
}

class _FallbackOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final host = proxyHost ?? uri.host;
      final port = proxyPort ?? (uri.port == 0 ? (uri.scheme == 'https' ? 443 : 80) : uri.port);
      final tls = proxyHost == null && uri.scheme == 'https';
      // Fast path: let the system resolve when it can.
      bool systemOk;
      try {
        systemOk = (await InternetAddress.lookup(host)
                .timeout(const Duration(seconds: 4)))
            .isNotEmpty;
      } catch (_) {
        systemOk = false;
      }
      if (systemOk) {
        return tls
            ? SecureSocket.startConnect(host, port, context: context)
            : Socket.startConnect(host, port);
      }
      final ip = (await WindowsDnsFallback.resolve(host)).first;
      final task = await Socket.startConnect(ip, port);
      final socket = task.socket.then<Socket>((raw) async {
        if (!tls) return raw;
        return SecureSocket.secure(raw, host: host, context: context);
      });
      return ConnectionTask.fromSocket(socket, task.cancel);
    };
    return client;
  }
}
