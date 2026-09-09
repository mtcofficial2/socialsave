import 'package:equatable/equatable.dart';
import 'package:social_save/shared/models/social_platform.dart';

class PlatformCapability extends Equatable {
  const PlatformCapability({
    required this.platform,
    required this.enabled,
    required this.supportsMetadata,
    required this.supportsDownload,
    this.notes,
  });

  final SocialPlatform platform;
  final bool enabled;
  final bool supportsMetadata;
  final bool supportsDownload;
  final String? notes;

  factory PlatformCapability.fromJson(Map<String, dynamic> json) {
    return PlatformCapability(
      platform: SocialPlatform.fromId(json['id'] as String?),
      enabled: json['enabled'] as bool? ?? false,
      supportsMetadata: json['supports_metadata'] as bool? ?? false,
      supportsDownload: json['supports_download'] as bool? ?? false,
      notes: json['notes'] as String?,
    );
  }

  static List<PlatformCapability> fallbackCatalog() {
    return SocialPlatform.supportedCatalog.map((platform) {
      return PlatformCapability(
        platform: platform,
        enabled: true,
        supportsMetadata: true,
        supportsDownload: true,
        notes: 'Public videos can be saved when the source is reachable without a login.',
      );
    }).toList();
  }

  @override
  List<Object?> get props =>
      [platform, enabled, supportsMetadata, supportsDownload, notes];
}
