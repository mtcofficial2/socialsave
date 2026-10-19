import 'package:social_save/features/library/session_ui.dart';
import 'package:social_save/web/web_pages.dart';
import 'package:social_save/features/player/presentation/screens/in_app_player_screen.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/library/nearby_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/theme/app_theme.dart';
import 'package:social_save/features/settings/presentation/providers/settings_controller.dart';
import 'package:social_save/shared/routing/app_router.dart';
import 'package:social_save/shared/widgets/glass.dart';
import 'package:window_manager/window_manager.dart';

class SocialSaveApp extends ConsumerWidget {
  const SocialSaveApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);

    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final dynamicOn = settings.useDynamicColor;
        return MaterialApp.router(
      scaffoldMessengerKey: kIsWeb ? webMessengerKey : null,
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
        final app = Stack(
          fit: StackFit.expand,
          children: [
            const GlassBackground(),
            if (child != null) Positioned.fill(child: _desktopKeys(child)),
            if (!kIsWeb) const NearbyIncomingCard(),
            if (!kIsWeb) const SessionPill(),
          ],
        );
        final scaled = MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3),
          ),
          child: app,
        );
        if (Plat.isWindows) return _TitleBarSync(brightness: Theme.of(context).brightness, child: scaled);
        return kIsWeb ? _WebPhoneFrame(child: scaled) : scaled;
      },
      routerConfig: appRouter,
    );
      },
    );
  }
}

/// Windows (1.0.45): the native title bar follows the app's light / dark
/// theme instead of the system setting, so the window chrome around the
/// player and every page matches.
class _TitleBarSync extends StatefulWidget {
  const _TitleBarSync({required this.brightness, required this.child});
  final Brightness brightness;
  final Widget child;

  @override
  State<_TitleBarSync> createState() => _TitleBarSyncState();
}

class _TitleBarSyncState extends State<_TitleBarSync> {
  Brightness? _applied;

  void _apply() {
    if (_applied == widget.brightness) return;
    _applied = widget.brightness;
    windowManager.setBrightness(widget.brightness).catchError((_) {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _apply());
  }

  @override
  void didUpdateWidget(_TitleBarSync old) {
    super.didUpdateWidget(old);
    if (old.brightness != widget.brightness) _apply();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
/// Windows: Esc and the mouse "back" button go back a screen.
Widget _desktopKeys(Widget child) {
  if (!Plat.isWindows) return child;
  void back() {
    if (appRouter.canPop()) appRouter.pop();
  }
  return Listener(
    onPointerDown: (event) {
      if (event.buttons & kBackMouseButton != 0) back();
    },
    child: CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          // The full-screen player handles Esc itself (exit full screen first).
          if (InAppPlayerScreen.openCount > 0) return;
          back();
        },
      },
      child: child,
    ),
  );
}

/// Web: the site is the phone app. On a wide browser window the phone
/// layout is shown centred at phone width instead of stretching.
class _WebPhoneFrame extends StatelessWidget {
  const _WebPhoneFrame({required this.child});

  final Widget child;

  static const double _phoneWidth = 440;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    if (media.size.width <= _phoneWidth + 48) return child;
    final scheme = Theme.of(context).colorScheme;
    final tall = media.size.height >= 760;
    final height = tall ? (media.size.height - 48).clamp(0.0, 940.0) : media.size.height;
    return ColoredBox(
      color: scheme.surfaceContainerLowest,
      child: Center(
        child: Container(
          width: _phoneWidth,
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(tall ? 28 : 0),
            border: Border.all(color: scheme.outlineVariant),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 40,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: MediaQuery(
            data: media.copyWith(size: Size(_phoneWidth, height)),
            child: child,
          ),
        ),
      ),
    );
  }
}
