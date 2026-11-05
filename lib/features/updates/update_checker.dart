import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/features/updates/release_version.dart';
import 'package:social_save/features/updates/update_controller.dart';

/// Asks GitHub when the app opens, when it comes back, and about once a minute
/// while it stays open. A force stop is not required for the prompt to show.
class UpdateChecker extends ConsumerStatefulWidget {
  const UpdateChecker({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<UpdateChecker> createState() => _UpdateCheckerState();
}

class _UpdateCheckerState extends ConsumerState<UpdateChecker>
    with WidgetsBindingObserver {
  Timer? _timer;
  String? _later;
  var _showing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(updateLookEvery, (_) {
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      unawaited(_check());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _check(force: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check(force: true));
  }

  Future<void> _check({bool force = false}) async {
    if (!mounted || _showing) return;
    await ref.read(updateControllerProvider.notifier).check(force: force);
    final update = ref.read(updateControllerProvider).update;
    if (update == null || !mounted || _showing) return;
    if (_later == update.version) return;
    _showing = true;
    final current = AppConstants.appVersion;
    var later = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Update available'),
          content: Text('SocialSave ${update.version} is ready. You have $current.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: () {
                later = false;
                Navigator.pop(dialogContext);
                ref.read(updateControllerProvider.notifier).downloadAndInstall();
              },
              child: const Text('Update'),
            ),
          ],
        ),
      );
    } finally {
      _showing = false;
      if (later) _later = update.version;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
