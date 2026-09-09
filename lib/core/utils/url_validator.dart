import 'package:social_save/core/constants/app_constants.dart';

class UrlValidationResult {
  const UrlValidationResult({
    required this.isValid,
    this.normalized,
    this.reason,
  });

  final bool isValid;
  final Uri? normalized;
  final String? reason;
}

class UrlValidator {
  const UrlValidator();

  static final RegExp _schemePattern = RegExp(r'^https?://', caseSensitive: false);

  UrlValidationResult validate(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const UrlValidationResult(
        isValid: false,
        reason: 'Paste a video URL to continue.',
      );
    }
    if (trimmed.length > AppConstants.maxUrlLength) {
      return const UrlValidationResult(
        isValid: false,
        reason: 'That URL is too long.',
      );
    }
    if (trimmed.contains(RegExp(r'\s'))) {
      return const UrlValidationResult(
        isValid: false,
        reason: 'URLs cannot contain spaces.',
      );
    }

    final withScheme = _schemePattern.hasMatch(trimmed)
        ? trimmed
        : 'https://$trimmed';

    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) {
      return const UrlValidationResult(
        isValid: false,
        reason: 'That does not look like a valid link.',
      );
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return const UrlValidationResult(
        isValid: false,
        reason: 'Only http and https URLs are allowed.',
      );
    }
    if (uri.userInfo.isNotEmpty) {
      return const UrlValidationResult(
        isValid: false,
        reason: 'URLs with embedded credentials are not allowed.',
      );
    }
    if (!_looksLikePublicHost(uri.host)) {
      return const UrlValidationResult(
        isValid: false,
        reason: 'That host cannot be used.',
      );
    }

    return UrlValidationResult(isValid: true, normalized: uri);
  }

  bool _looksLikePublicHost(String host) {
    final lower = host.toLowerCase();
    if (lower == 'localhost' || lower.endsWith('.localhost')) {
      return false;
    }
    final ip = Uri.parse('http://$lower').host;
    if (_isBlockedIpLiteral(ip)) {
      return false;
    }
    return lower.contains('.');
  }

  bool _isBlockedIpLiteral(String host) {
    final ipv4 = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');
    if (!ipv4.hasMatch(host)) {
      return false;
    }
    final parts = host.split('.').map(int.parse).toList();
    if (parts.any((part) => part > 255)) {
      return true;
    }
    final a = parts[0];
    final b = parts[1];
    if (a == 10 || a == 127 || a == 0 || a == 169 && b == 254) {
      return true;
    }
    if (a == 192 && b == 168) {
      return true;
    }
    if (a == 172 && b >= 16 && b <= 31) {
      return true;
    }
    return false;
  }
}
