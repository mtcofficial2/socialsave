/// A page the phone may open itself. The chat server never fetches this URL.
bool chatLinkAllowed(Uri? uri) {
  if (uri == null || !uri.hasScheme || uri.scheme != 'https') return false;
  if (!uri.hasAuthority || uri.userInfo.isNotEmpty) return false;
  final host = uri.host.toLowerCase();
  if (host.isEmpty || host == 'localhost' || host.endsWith('.localhost') || host.endsWith('.local')) {
    return false;
  }
  if (host == '0.0.0.0' || host == '::1' || host == '[::1]') return false;
  if (host.startsWith('[')) return false;
  return !_privateIpv4(host);
}

bool _privateIpv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final nums = <int>[];
  for (final part in parts) {
    if (part.isEmpty || part.length > 3) return true;
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return true;
    nums.add(value);
  }
  final a = nums[0];
  final b = nums[1];
  if (a == 0 || a == 10 || a == 127) return true;
  if (a == 192 && b == 168) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 169 && b == 254) return true;
  if (a == 100 && b >= 64 && b <= 127) return true;
  return false;
}
