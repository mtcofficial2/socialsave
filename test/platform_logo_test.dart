import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/widgets/app_logo.dart';
import 'package:social_save/shared/widgets/platform_logo.dart';

void main() {
  test('a bare mark is a separate file from the tiled logo', () {
    expect(PlatformLogo.assetFor(SocialPlatform.youtube), 'assets/platforms/youtube.svg');
    expect(PlatformLogo.assetFor(SocialPlatform.youtube, bare: true), 'assets/platforms/youtube_mark.svg');
    expect(PlatformLogo.assetFor(SocialPlatform.x, bare: true), 'assets/platforms/x_mark.svg');
    expect(PlatformLogo.assetFor(SocialPlatform.unknown, bare: true), isNull);
  });

  testWidgets('the logo and platform marks paint', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              AppLogo(size: 32, showWordmark: true),
              PlatformLogo(platform: SocialPlatform.youtube, size: 24),
              PlatformLogo(platform: SocialPlatform.instagram, size: 24),
              PlatformLogo(platform: SocialPlatform.tiktok, size: 24),
              PlatformLogo(platform: SocialPlatform.x, size: 24),
              PlatformLogo(platform: SocialPlatform.facebook, size: 24),
              PlatformLogo(platform: SocialPlatform.reddit, size: 24),
              PlatformLogo(platform: SocialPlatform.pinterest, size: 24),
              PlatformLogo(platform: SocialPlatform.direct, size: 24),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppLogo), findsOneWidget);
    expect(find.text('SocialSave'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
