enum SocialPlatform {
  tiktok,
  instagram,
  facebook,
  x,
  youtube,
  reddit,
  pinterest,
  direct,
  unknown;

  String get id {
    switch (this) {
      case SocialPlatform.tiktok:
        return 'tiktok';
      case SocialPlatform.instagram:
        return 'instagram';
      case SocialPlatform.facebook:
        return 'facebook';
      case SocialPlatform.x:
        return 'x';
      case SocialPlatform.youtube:
        return 'youtube';
      case SocialPlatform.reddit:
        return 'reddit';
      case SocialPlatform.pinterest:
        return 'pinterest';
      case SocialPlatform.direct:
        return 'direct';
      case SocialPlatform.unknown:
        return 'unknown';
    }
  }

  String get displayName {
    switch (this) {
      case SocialPlatform.tiktok:
        return 'TikTok';
      case SocialPlatform.instagram:
        return 'Instagram';
      case SocialPlatform.facebook:
        return 'Facebook';
      case SocialPlatform.x:
        return 'X';
      case SocialPlatform.youtube:
        return 'YouTube';
      case SocialPlatform.reddit:
        return 'Reddit';
      case SocialPlatform.pinterest:
        return 'Pinterest';
      case SocialPlatform.direct:
        return 'Direct URL';
      case SocialPlatform.unknown:
        return 'Unknown';
    }
  }

  String get letter {
    switch (this) {
      case SocialPlatform.tiktok:
        return 'TT';
      case SocialPlatform.instagram:
        return 'IG';
      case SocialPlatform.facebook:
        return 'FB';
      case SocialPlatform.x:
        return 'X';
      case SocialPlatform.youtube:
        return 'YT';
      case SocialPlatform.reddit:
        return 'RD';
      case SocialPlatform.pinterest:
        return 'PN';
      case SocialPlatform.direct:
        return 'URL';
      case SocialPlatform.unknown:
        return '?';
    }
  }

  static SocialPlatform fromId(String? value) {
    switch (value?.toLowerCase()) {
      case 'tiktok':
        return SocialPlatform.tiktok;
      case 'instagram':
        return SocialPlatform.instagram;
      case 'facebook':
        return SocialPlatform.facebook;
      case 'x':
      case 'twitter':
        return SocialPlatform.x;
      case 'youtube':
        return SocialPlatform.youtube;
      case 'reddit':
        return SocialPlatform.reddit;
      case 'pinterest':
        return SocialPlatform.pinterest;
      case 'direct':
        return SocialPlatform.direct;
      default:
        return SocialPlatform.unknown;
    }
  }

  static const List<SocialPlatform> supportedCatalog = [
    SocialPlatform.tiktok,
    SocialPlatform.instagram,
    SocialPlatform.facebook,
    SocialPlatform.x,
    SocialPlatform.youtube,
    SocialPlatform.reddit,
    SocialPlatform.pinterest,
    SocialPlatform.direct,
  ];
}
