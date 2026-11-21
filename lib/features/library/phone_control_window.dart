import 'dart:io';

import 'package:flutter/material.dart';
import 'package:social_save/core/theme/app_colors.dart';
import 'package:social_save/features/library/phone_control_open.dart';
import 'package:social_save/features/library/phone_control_ui.dart';
import 'package:social_save/features/library/usb_link.dart';
import 'package:window_manager/window_manager.dart';

/// `SocialSave.exe --phone-control`. Its own window, not a sheet on the main app.
Future<void> runPhoneControlWindow() async {
  if (!Platform.isWindows) return;
  if (!claimPhoneControlWindow()) {
    for (var i = 0; i < 25; i++) {
      if (focusPhoneControlWindow()) break;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    exit(0);
  }
  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(1180, 820),
    minimumSize: Size(960, 680),
    center: true,
    title: phoneControlWindowTitle,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.setTitle(phoneControlWindowTitle);
    await windowManager.show();
    await windowManager.focus();
  });
  await UsbLink.prepareControl();
  runApp(const PhoneControlApp());
}

/// The whole window is the phone. Closing it leaves the main Social Save window open.
class PhoneControlApp extends StatelessWidget {
  const PhoneControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = AppColors.seed;
    return MaterialApp(
      title: phoneControlWindowTitle,
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
      ),
      home: const Scaffold(body: PhoneControlSheet(windowed: true)),
    );
  }
}
