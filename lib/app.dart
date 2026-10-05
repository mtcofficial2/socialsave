import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/theme/app_theme.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';
import 'package:social_save/shared/routing/app_router.dart';
import 'package:social_save/shared/widgets/glass.dart';

class SocialSaveApp extends ConsumerWidget {
  const SocialSaveApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);

    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final dynamicOn = settings.useDynamicColor;
        return MaterialApp.router(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(
        fontFamily: settings.fontFamily,
        colorScheme: dynamicOn ? lightDynamic : null,
      ),
      darkTheme: AppTheme.dark(
        fontFamily: settings.fontFamily,
        colorScheme: dynamicOn ? darkDynamic : null,
      ),
      themeMode: settings.themeMode,
      builder: (context, child) {
        return Stack(
          fit: StackFit.expand,
          children: [
            const GlassBackground(),
            if (child != null) Positioned.fill(child: child),
          ],
        );
      },
      routerConfig: appRouter,
    );
      },
    );
  }
}
