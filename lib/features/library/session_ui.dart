import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:social_save/features/library/hotspot_share.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:social_save/core/constants/app_constants.dart';
import 'package:social_save/core/platform/media_events.dart';
import 'package:social_save/core/platform/plat.dart';
import 'package:social_save/features/library/phone_handoff.dart';
import 'package:social_save/features/library/session_keepalive.dart';
import 'package:social_save/features/player/presentation/screens/in_app_player_screen.dart';
import 'package:social_save/features/library/bundle_transfer.dart';
import 'package:social_save/features/library/nearby_service.dart';
import 'package:social_save/features/library/session_media_picker.dart';
import 'package:social_save/features/library/share_session.dart';
import 'package:social_save/features/library/transfer_meter.dart';
import 'package:social_save/features/player/player_session.dart';
import 'package:social_save/shared/models/social_platform.dart';
import 'package:social_save/shared/routing/app_router.dart';

/// Hooks [ShareSession] to the UI. Called from installNearbyUi().
void installSessionUi() {
  ShareSession.install();
  ShareSession.onRequest = (name, kind) async {
    final context = appRouter.routerDelegate.navigatorKey.currentContext;
    if (context == null || !context.mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.link_rounded),
        title: Text('$name wants to connect'),
        content: const Text(
          'While connected, you can both send videos and files to each other '
          'without scanning again. Files from them are saved automatically.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Decline')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Connect')),
        ],
      ),
    );
    return ok == true;
  };
  ShareSession.onOpened = () => unawaited(landOnSession());
  SessionKeepAlive.onOpen = () => unawaited(openSessionScreen());
  SessionKeepAlive.wire();
  SessionPeer? before;
  ShareSession.peer.addListener(() {
    final now = ShareSession.peer.value;
    if (now != null && before == null) unawaited(_afterConnected());
    before = now;
  });
}

const _batteryAskedKey = 'session_battery_asked';

/// First connection on Android: notifications (for the "Connected" and
/// "File received" notices) and, once, the battery exemption so the link
/// survives the screen going off.
Future<void> _afterConnected() async {
  if (!SessionKeepAlive.supported) return;
  await Future<void>.delayed(const Duration(milliseconds: 800));
  try {
    final st = await Permission.notification.status;
    if (!st.isGranted && !st.isPermanentlyDenied) await Permission.notification.request();
  } catch (_) {}
  if (await SessionKeepAlive.batteryExempt()) return;
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_batteryAskedKey) == true) return;
  await prefs.setBool(_batteryAskedKey, true);
  final context = appRouter.routerDelegate.navigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  await askBatteryExemption(context);
}

/// Explains and asks Android to let SocialSave run in the background.
Future<void> askBatteryExemption(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.battery_saver_rounded),
      title: const Text('Stay connected in the background'),
      content: const Text(
        'So the connection keeps going when the screen turns off or you switch apps, '
        'allow SocialSave to run without battery restrictions.\n\n'
        'It only stays active while you are connected, and stops when you press Disconnect.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Allow')),
      ],
    ),
  );
  if (ok == true) await SessionKeepAlive.requestBatteryExempt();
}

/// "Disconnect from X?" — the only way a session ends on purpose.
Future<void> confirmDisconnect(BuildContext context) async {
  final p = ShareSession.peer.value;
  if (p == null) return;
  final busy = ShareSession.items.where((i) => i.active || i.state == SessionItemState.queued).length;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.link_off_rounded),
      title: Text('Disconnect from ${p.name}?'),
      content: Text(busy > 0
          ? '$busy transfer${busy == 1 ? ' is' : 's are'} still going and will stop. '
              'You can connect again any time.'
          : 'You can connect again any time. Files already received stay saved.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Stay connected')),
        FilledButton(
          key: const ValueKey('session-disconnect-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Disconnect'),
        ),
      ],
    ),
  );
  if (ok == true) await ShareSession.disconnect();
}

/// Queues [file] for the connected device and says so.
void sendToSessionPeer(BuildContext context, File file) {
  final p = ShareSession.peer.value;
  if (p == null) return;
  ShareSession.enqueue([file]);
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
    content: Text('Sending to ${p.name}…'),
    action: SnackBarAction(label: 'View', onPressed: () => unawaited(openSessionScreen())),
  ));
}

/// While connected, "Send to another device" first offers the connected
/// device. Returns true when the file was queued (or the user cancelled).
Future<bool> offerSessionSend(BuildContext context, File file, String title) async {
  final p = ShareSession.peer.value;
  if (p == null) return false;
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      final theme = Theme.of(context);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const ValueKey('session-quick-send'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                onPressed: () => Navigator.pop(context, 'session'),
                icon: Icon(p.kind == 'pc' ? Icons.computer_rounded : Icons.smartphone_rounded),
                label: Text('Send to ${p.name}', overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: () => Navigator.pop(context, 'other'),
                icon: const Icon(Icons.qr_code_rounded),
                label: const Text('Other ways (QR, code)'),
              ),
            ],
          ),
        ),
      );
    },
  );
  if (choice == 'session') {
    if (context.mounted) sendToSessionPeer(context, file);
    return true;
  }
  return choice != 'other';
}

/// Wraps pairing UI (QR / code dialogs, Connect picker, Receive sheet) so it
/// closes by itself the moment a session opens.
class PairingUiScope extends StatefulWidget {
  const PairingUiScope({super.key, required this.child});
  final Widget child;

  @override
  State<PairingUiScope> createState() => _PairingUiScopeState();
}

class _PairingUiScopeState extends State<PairingUiScope> {
  late final void Function() _close = () {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    final nav = Navigator.of(context);
    if (route.isCurrent) {
      nav.pop();
    } else {
      nav.removeRoute(route);
    }
  };

  @override
  void initState() {
    super.initState();
    ShareSession.pairingUi.add(_close);
  }

  @override
  void dispose() {
    ShareSession.pairingUi.remove(_close);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A session just opened (either side): close every pairing dialog/sheet,
/// then show the Connected screen with a short "Connected to X" toast. If
/// the user is watching something, don't interrupt: the pill shows instead.
Future<void> landOnSession() async {
  final p = ShareSession.peer.value;
  if (p == null) return;
  for (final close in ShareSession.pairingUi.toList()) {
    try {
      close();
    } catch (_) {}
  }
  ShareSession.pairingUi.clear();
  final nav = appRouter.routerDelegate.navigatorKey.currentState;
  if (nav == null) return;
  // Any other dialog left on top (e.g. a Watch/Save choice) goes too.
  var popped = 0;
  nav.popUntil((route) {
    if (route is PopupRoute && !route.isFirst) {
      popped++;
      return false;
    }
    return true;
  });
  debugPrint('[session] landed: closed $popped dialog(s)');
  await Future<void>.delayed(const Duration(milliseconds: 50));
  final messenger = ScaffoldMessenger.maybeOf(nav.context);
  messenger?.hideCurrentSnackBar();
  final watching = InAppPlayerScreen.openCount > 0;
  if (!watching && !ShareSession.screenOpen) unawaited(openSessionScreen());
  await Future<void>.delayed(const Duration(milliseconds: 300));
  ShareSession.landOnTransfers = false;
  final offerUpdate = p.older && p.kind == 'phone' && !watching;
  messenger?.showSnackBar(SnackBar(
    duration: Duration(seconds: offerUpdate ? 6 : 2),
    content: Text(p.legacy
        ? 'Connected to ${p.name} · it has an older SocialSave'
        : 'Connected to ${p.name}${offerUpdate ? ' · it has an older SocialSave' : ''}'),
    action: watching
        ? SnackBarAction(label: 'Open', onPressed: () => unawaited(openSessionScreen()))
        : offerUpdate
            ? SnackBarAction(
                label: 'Send update',
                onPressed: () {
                  final ctx = appRouter.routerDelegate.navigatorKey.currentContext;
                  if (ctx != null) unawaited(sendAppToPeer(ctx));
                },
              )
            : null,
  ));
}

/// Shows the "Connected to …" screen (once).
Future<void> openSessionScreen([BuildContext? from]) async {
  if (ShareSession.screenOpen) return;
  final context = from ?? appRouter.routerDelegate.navigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  ShareSession.screenOpen = true;
  try {
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(builder: (_) => const SessionScreen()),
    );
  } finally {
    ShareSession.screenOpen = false;
  }
}

/// Pick a nearby device (same Wi-Fi, USB cable, PC) and stay connected to it.
Future<void> showConnectPicker(BuildContext context) async {
  if (ShareSession.active) {
    await openSessionScreen(context);
    return;
  }
  NearbyService.ping();
  final device = await showDialog<NearbyDevice>(
    context: context,
    builder: (context) => PairingUiScope(child: AlertDialog(
      icon: const Icon(Icons.link_rounded),
      title: const Text('Connect to a device'),
      content: SizedBox(
        width: 420,
        child: ValueListenableBuilder<List<NearbyDevice>>(
          valueListenable: NearbyService.devices,
          builder: (context, list, _) {
            final small = Theme.of(context).textTheme.bodySmall;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Stay connected and send videos or files both ways, as many times as you like.',
                  style: small,
                ),
                const SizedBox(height: 12),
                if (list.isEmpty)
                  const Row(
                    children: [
                      SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 10),
                      Expanded(child: Text('Looking for SocialSave on this Wi-Fi or USB cable…')),
                    ],
                  )
                else
                  for (final d in list)
                    ListTile(
                      key: ValueKey('connect-${d.id}-${d.link}'),
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(d.isCable
                          ? Icons.cable_rounded
                          : (d.isPc ? Icons.computer_rounded : Icons.smartphone_rounded)),
                      title: Text(d.name),
                      subtitle: Text('${d.playerName} · ${d.isCable ? 'cable' : 'Wi-Fi'}'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.pop(context, d),
                    ),
                const SizedBox(height: 8),
                Text(
                  Plat.isAndroid
                      ? 'No Wi-Fi? Use Send › Fast share (hotspot): scanning its QR connects you too.'
                      : 'Phone on its own hotspot? Join that Wi-Fi on this PC, then it shows up here.',
                  style: small,
                ),
              ],
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    )),
  );
  if (device == null || !context.mounted || ShareSession.active) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(
    duration: const Duration(seconds: 60),
    content: Text('Waiting for ${device.name} to accept…'),
  ));
  final error = await ShareSession.connect(host: device.host, port: device.port, link: device.link);
  if (error != null) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(error)));
    return;
  }
  // Success: landOnSession() already closed this and opened the screen.
  if (context.mounted && !ShareSession.screenOpen && InAppPlayerScreen.openCount == 0) {
    await openSessionScreen(context);
  }
}

/// Hotspot details (name, password, Wi-Fi QR) of the running session, so a
/// third device can still join. Null when the session isn't on a hotspot.
({String ssid, String password})? sessionHotspotDetails() {
  final info = HotspotShare.lastInfo;
  if (ShareSession.hostsHotspot && info != null) {
    return (ssid: info.ssid, password: info.password);
  }
  final join = HotspotShare.lastJoin;
  if (ShareSession.joinedHotspot && join != null) return (ssid: join.ssid, password: join.password);
  return null;
}

String _wifiEsc(String v) => v.replaceAllMapped(RegExp(r'([\\;,:"])'), (m) => '\\${m[1]}');

bool get sessionHasCode => sessionHotspotDetails() != null || PhoneHandoff.current != null;

Widget _qr(String data, String key, {double size = 180}) => Container(
      color: Colors.white,
      padding: const EdgeInsets.all(8),
      child: QrImageView(key: ValueKey(key), data: data, size: size),
    );

Future<void> showSessionHotspotCode(BuildContext context) async {
  final d = sessionHotspotDetails();
  final offer = PhoneHandoff.current;
  if (d == null && offer == null) return;
  final link = ShareSession.pairLink ?? offer?.url;
  await showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final small = theme.textTheme.bodySmall;
      Widget row(String label, String value, String key) => ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(label, style: small),
            subtitle: SelectableText(value, key: ValueKey(key), style: theme.textTheme.titleMedium),
            trailing: IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy_rounded),
              onPressed: () => Clipboard.setData(ClipboardData(text: value)),
            ),
          );
      return AlertDialog(
        key: const ValueKey('session-code-dialog'),
        icon: const Icon(Icons.qr_code_2_rounded),
        title: const Text('Show code'),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (link != null && offer != null) ...[
                  _qr(link, 'session-code-link'),
                  const SizedBox(height: 6),
                  Text('On the other device: SocialSave › Receive › scan this. '
                      'An older SocialSave gets the next file this way.',
                      style: small, textAlign: TextAlign.center),
                  row('Code', ShareSession.legacyCode(), 'session-code-code'),
                ],
                if (d != null) ...[
                  if (link != null && offer != null) const Divider(),
                  _qr('WIFI:T:WPA;S:${_wifiEsc(d.ssid)};P:${_wifiEsc(d.password)};;', 'session-code-qr', size: 150),
                  const SizedBox(height: 6),
                  Text('Join this Wi-Fi with the camera, or by hand:', style: small, textAlign: TextAlign.center),
                  row('Wi-Fi name', d.ssid, 'session-code-ssid'),
                  row('Password', d.password, 'session-code-pass'),
                ],
              ],
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      );
    },
  );
}

/// This app's installer, to update the other phone: Android sends its own
/// APK; Windows uses SocialSave.apk next to SocialSave.exe (the portable zip
/// ships one) or the newest SocialSave*.apk on the Desktop / in Downloads.
Future<File?> findShareableApk() async {
  final name = 'SocialSave-${AppConstants.appVersion}.apk';
  try {
    if (Plat.isAndroid) {
      final src = await MediaEvents.channel.invokeMethod<String>('apkPath');
      if (src == null || !File(src).existsSync()) return null;
      final out = File('${Directory.systemTemp.path}/$name');
      if (!out.existsSync() || out.lengthSync() != File(src).lengthSync()) await File(src).copy(out.path);
      return out;
    }
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final bundled = File('$exeDir${Platform.pathSeparator}SocialSave.apk');
    if (bundled.existsSync()) return bundled;
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
    final found = <File>[];
    for (final dir in ['$home${Platform.pathSeparator}Desktop', '$home${Platform.pathSeparator}Downloads']) {
      final d = Directory(dir);
      if (!d.existsSync()) continue;
      for (final e in d.listSync()) {
        final n = e.path.split(RegExp(r'[\\/]')).last.toLowerCase();
        if (e is File && n.startsWith('socialsave') && n.endsWith('.apk')) found.add(e);
      }
    }
    if (found.isEmpty) return null;
    found.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return found.first;
  } catch (e) {
    debugPrint('[session] no apk: $e');
    return null;
  }
}

/// "Send SocialSave to the other phone": over the session when it can take
/// files; for an older app, through the phone's browser (same hotspot/Wi-Fi).
Future<void> sendAppToPeer(BuildContext context) async {
  final peer = ShareSession.peer.value;
  if (peer == null) return;
  final messenger = ScaffoldMessenger.of(context);
  final apk = await findShareableApk();
  if (apk == null) {
    messenger.showSnackBar(SnackBar(
      content: Text(Plat.isWindows
          ? 'No SocialSave APK found. Put SocialSave.apk next to SocialSave.exe (or on the Desktop) and try again.'
          : 'Could not find this app\'s installer.'),
    ));
    return;
  }
  if (!peer.legacy) {
    ShareSession.enqueue([apk]);
    messenger.showSnackBar(SnackBar(
      content: Text('Sending SocialSave ${AppConstants.appVersion} to ${peer.name}. '
          'On ${peer.name}: tap it in Transfers to install.'),
    ));
    return;
  }
  PhoneHandoff.apkFile = apk;
  final url = PhoneHandoff.apkUrl();
  if (url == null || !context.mounted) return;
  final d = sessionHotspotDetails();
  await showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final small = theme.textTheme.bodySmall;
      return AlertDialog(
        key: const ValueKey('send-app-dialog'),
        icon: const Icon(Icons.system_update_rounded),
        title: Text('Send SocialSave ${AppConstants.appVersion}'),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (d != null) ...[
                  Text('1. On ${peer.name}, join the Wi-Fi "${d.ssid}" (scan with the camera):', style: small),
                  const SizedBox(height: 6),
                  Center(child: _qr('WIFI:T:WPA;S:${_wifiEsc(d.ssid)};P:${_wifiEsc(d.password)};;', 'send-app-wifi', size: 140)),
                  const SizedBox(height: 10),
                ],
                Text('${d != null ? '2. ' : ''}Scan this with the phone\'s camera (or open the link in its browser) '
                    'to download SocialSave, then tap it to install:', style: small),
                const SizedBox(height: 6),
                Center(child: _qr(url, 'send-app-url', size: 170)),
                const SizedBox(height: 4),
                SelectableText(url, key: const ValueKey('send-app-link'), textAlign: TextAlign.center, style: small),
                const SizedBox(height: 8),
                Text('After updating, scan the code again: both phones then stay connected and send both ways.',
                    style: small),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              ShareSession.enqueue([apk]);
              Navigator.pop(context);
            },
            child: const Text('Queue it for Receive instead'),
          ),
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
        ],
      );
    },
  );
}

/// Slim "Connected to …" strip for the share cards, so a session that runs
/// in the background is one tap away.
class SessionBanner extends StatelessWidget {
  const SessionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SessionPeer?>(
      valueListenable: ShareSession.peer,
      builder: (context, peer, _) {
        if (peer == null) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return ValueListenableBuilder<String>(
          valueListenable: ShareSession.state,
          builder: (context, state, _) {
            final re = state == 'reconnecting';
            final bg = re ? scheme.tertiaryContainer : scheme.primaryContainer;
            final fg = re ? scheme.onTertiaryContainer : scheme.onPrimaryContainer;
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Material(
                color: bg,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  key: const ValueKey('session-banner'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => openSessionScreen(context),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        Icon(re ? Icons.sync_rounded : Icons.link_rounded, color: fg, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            re ? 'Reconnecting to ${peer.name}…' : 'Connected to ${peer.name} · ${peer.linkLabel}',
                            style: TextStyle(color: fg, fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text('Open', style: TextStyle(color: fg)),
                        Icon(Icons.chevron_right_rounded, color: fg),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Floating "Connected to X" pill shown over the whole app (Home, Library,
/// the player…) while a session runs; tap to reopen the session.
class SessionPill extends StatelessWidget {
  const SessionPill({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        ShareSession.peer,
        ShareSession.state,
        ShareSession.screenVisible,
        ShareSession.revision,
        NearbyService.incoming,
        appRouter.routerDelegate,
      ]),
      builder: (context, _) {
        final peer = ShareSession.peer.value;
        if (peer == null || ShareSession.screenOpen) return const SizedBox.shrink();
        // The incoming card is showing (it says the same and more).
        final inc = NearbyService.incoming.value;
        if (inc != null && !inc.done) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final mq = MediaQuery.of(context);
        final re = ShareSession.state.value == 'reconnecting';
        final busy = ShareSession.items.where((i) => i.active || i.state == SessionItemState.queued).length;
        final inPlayer = InAppPlayerScreen.openCount > 0;
        final bg = re ? scheme.tertiaryContainer : scheme.primaryContainer;
        final fg = re ? scheme.onTertiaryContainer : scheme.onPrimaryContainer;
        final pill = Material(
          color: bg.withValues(alpha: 0.96),
          elevation: 4,
          shape: const StadiumBorder(),
          child: InkWell(
            key: const ValueKey('session-pill'),
            customBorder: const StadiumBorder(),
            onTap: () => unawaited(openSessionScreen()),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (re)
                    SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
                  else
                    Icon(busy > 0 ? Icons.swap_vert_rounded : Icons.link_rounded, size: 18, color: fg),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: mq.size.width * 0.6),
                    child: Text(
                      re
                          ? 'Reconnecting to ${peer.name}…'
                          : busy > 0
                              ? '${peer.name} · $busy transfer${busy == 1 ? '' : 's'}'
                              : 'Connected to ${peer.name}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 18, color: fg),
                ],
              ),
            ),
          ),
        );
        if (Plat.isWindows) {
          return Positioned(right: 16, bottom: 16, child: pill);
        }
        return Positioned(
          left: 0,
          right: 0,
          top: inPlayer ? mq.padding.top + 56 : null,
          bottom: inPlayer ? null : mq.padding.bottom + 92,
          child: Center(child: pill),
        );
      },
    );
  }
}

/// "Connected to <device>": send more at any time, see what came in.
class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key});

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> with SingleTickerProviderStateMixin {
  SessionPeer? _last;
  bool _picking = false;
  bool _reconnecting = false;
  bool? _exempt;
  // A file picked before connecting is already the first transfer: show it.
  late final TabController _tabs =
      TabController(length: 2, vsync: this, initialIndex: ShareSession.items.isNotEmpty || ShareSession.landOnTransfers ? 1 : 0);

  @override
  void initState() {
    super.initState();
    unawaited(_checkBattery());
  }

  Future<void> _checkBattery() async {
    final v = await SessionKeepAlive.batteryExempt();
    if (mounted) setState(() => _exempt = v);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// Media picked in the grid: queue them and show the transfer list.
  Future<void> _sendPicked(List<MediaEntry> picked) async {
    final files = <File>[];
    var missing = 0;
    for (final e in picked) {
      final f = await MediaCatalog.fileFor(e);
      if (f == null) {
        missing++;
      } else {
        files.add(f);
      }
    }
    if (!mounted) return;
    if (files.isNotEmpty) ShareSession.enqueue(files);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text([
        if (files.isNotEmpty) 'Sending ${files.length} item${files.length == 1 ? '' : 's'}',
        if (missing > 0) '$missing could not be opened',
      ].join(' · ')),
    ));
    if (files.isNotEmpty) _tabs.animateTo(1);
  }

  Future<void> _send({required bool folder}) async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final bundle = folder ? await pickAnyFolder() : await pickAnyFiles();
      if (bundle == null) return;
      ShareSession.enqueue([for (final it in bundle.items) it.file]);
      if (mounted) _tabs.animateTo(1);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open the picker: $e')));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _reconnect() async {
    if (_reconnecting) return;
    setState(() => _reconnecting = true);
    final err = await ShareSession.reconnect();
    if (!mounted) return;
    setState(() => _reconnecting = false);
    if (err != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
  }

  void _openPath(String path, String name) {
    if (Plat.isAndroid && path.toLowerCase().endsWith('.apk')) {
      unawaited(MediaEvents.channel.invokeMethod<bool>('installApk', {'path': path}));
      return;
    }
    if (FileSystemEntity.isDirectorySync(path)) {
      unawaited(openWithSystem(path));
    } else if (isVideoName(path)) {
      unawaited(appRouter.push(
        '/player',
        extra: PlayerSession(title: name, platform: SocialPlatform.direct, filePath: path),
      ));
    } else {
      unawaited(openWithSystem(path));
    }
  }

  void _open(SessionItem it) {
    final f = it.file;
    if (f == null) return;
    _openPath(f.path, it.name);
  }

  Widget _updateBanner(BuildContext context, SessionPeer peer) {
    final scheme = Theme.of(context).colorScheme;
    final phone = peer.kind == 'phone';
    final text = peer.legacy
        ? '${peer.name} is on an older SocialSave. Update it to send both ways. '
            'Until then it gets each file by receiving again (Show code).'
        : '${peer.name} has an older SocialSave${peer.version == null ? '' : ' (${peer.version})'}. '
            '${phone ? 'Send the update' : 'Update it'} so both have the newest sharing.';
    return _Banner(
      color: scheme.tertiaryContainer,
      onColor: scheme.onTertiaryContainer,
      icon: Icons.system_update_rounded,
      text: text,
      action: phone
          ? FilledButton.tonalIcon(
              key: const ValueKey('session-send-app'),
              onPressed: () => sendAppToPeer(context),
              icon: const Icon(Icons.install_mobile_rounded),
              label: const Text('Send SocialSave'),
            )
          : null,
    );
  }

  Widget _stateBanner(BuildContext context, SessionPeer? peer, String state) {
    final scheme = Theme.of(context).colorScheme;
    if (peer == null && state == 'connecting') {
      return _Banner(
        color: scheme.secondaryContainer,
        onColor: scheme.onSecondaryContainer,
        icon: Icons.link_rounded,
        busy: true,
        text: 'Connecting…',
      );
    }
    if (peer == null) {
      final last = ShareSession.lastPeer ?? _last;
      final canReconnect = last != null;
      return _Banner(
        color: scheme.errorContainer,
        onColor: scheme.onErrorContainer,
        icon: Icons.link_off_rounded,
        text: ShareSession.endReason.isEmpty ? 'Disconnected.' : ShareSession.endReason,
        action: canReconnect
            ? FilledButton.tonalIcon(
                key: const ValueKey('session-reconnect'),
                onPressed: _reconnecting ? null : _reconnect,
                icon: _reconnecting
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh_rounded),
                label: const Text('Reconnect'),
              )
            : null,
      );
    }
    if (state == 'reconnecting') {
      return _Banner(
        color: scheme.tertiaryContainer,
        onColor: scheme.onTertiaryContainer,
        icon: Icons.sync_rounded,
        busy: true,
        text: 'Reconnecting to ${peer.name}… Transfers continue when it\'s back. '
            'Keep Wi-Fi on${peer.link == 'hotspot' ? ' and stay near the other phone' : ''}.',
      );
    }
    return _Banner(
      color: scheme.primaryContainer,
      onColor: scheme.onPrimaryContainer,
      icon: Icons.check_circle_rounded,
      text: 'Connected · you can leave this screen or the app — it stays connected until you press Disconnect.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ValueListenableBuilder<SessionPeer?>(
      valueListenable: ShareSession.peer,
      builder: (context, peer, _) {
        if (peer != null) _last = peer;
        final shown = peer ?? _last ?? ShareSession.lastPeer;
        return ValueListenableBuilder<String>(
          valueListenable: ShareSession.state,
          builder: (context, state, _) => Scaffold(
            appBar: AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    peer == null
                        ? (state == 'connecting' ? 'Connecting…' : 'Disconnected')
                        : state == 'reconnecting'
                            ? 'Reconnecting to ${peer.name}…'
                            : 'Connected to ${peer.name}',
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (shown != null)
                    Text(
                      '${shown.kind == 'pc' ? 'PC' : 'Phone'} · ${shown.linkLabel}',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
              bottom: TabBar(
                controller: _tabs,
                tabs: [
                  const Tab(key: ValueKey('session-tab-media'), icon: Icon(Icons.video_library_rounded), text: 'Pick media'),
                  Tab(
                    key: const ValueKey('session-tab-transfers'),
                    icon: const Icon(Icons.swap_vert_rounded),
                    child: ValueListenableBuilder<int>(
                      valueListenable: ShareSession.revision,
                      builder: (context, _, __) {
                        final active = ShareSession.items.where((i) => i.active || i.state == SessionItemState.queued).length;
                        return Text(active > 0 ? 'Transfers ($active)' : 'Transfers');
                      },
                    ),
                  ),
                ],
              ),
              actions: [
                if (sessionHasCode)
                  IconButton(
                    key: const ValueKey('session-show-code'),
                    tooltip: 'Show code (hotspot name, password, QR)',
                    icon: const Icon(Icons.qr_code_2_rounded),
                    onPressed: () => showSessionHotspotCode(context),
                  ),
                if (peer != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: TextButton.icon(
                      key: const ValueKey('session-disconnect'),
                      style: TextButton.styleFrom(foregroundColor: scheme.error),
                      onPressed: () => confirmDisconnect(context),
                      icon: const Icon(Icons.link_off_rounded),
                      label: const Text('Disconnect'),
                    ),
                  ),
              ],
            ),
            body: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _stateBanner(context, peer, state),
                  if (peer != null && peer.older) _updateBanner(context, peer),
                  if (peer != null && _exempt == false && SessionKeepAlive.supported)
                    Material(
                      color: scheme.surfaceContainerHigh,
                      child: ListTile(
                        dense: true,
                        leading: const Icon(Icons.battery_alert_rounded),
                        title: const Text('Battery saver may pause the connection when the screen is off'),
                        trailing: TextButton(
                          onPressed: () async {
                            await askBatteryExemption(context);
                            await Future<void>.delayed(const Duration(seconds: 2));
                            await _checkBattery();
                          },
                          child: const Text('Fix'),
                        ),
                      ),
                    ),
                  Expanded(
                    child: TabBarView(
                      controller: _tabs,
                      children: [
                        SessionMediaPicker(
                          enabled: peer != null,
                          onBrowseFiles: () => _send(folder: false),
                          onSend: _sendPicked,
                        ),
                        _transfersTab(context, peer, shown),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _transfersTab(BuildContext context, SessionPeer? peer, SessionPeer? shown) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('session-send'),
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
                  onPressed: peer == null || _picking ? null : () => _send(folder: false),
                  icon: const Icon(Icons.send_rounded),
                  label: const Text('Browse files'),
                ),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                key: const ValueKey('session-send-folder'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 56)),
                onPressed: peer == null || _picking ? null : () => _send(folder: true),
                icon: const Icon(Icons.drive_folder_upload_rounded),
                label: const Text('Folder'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: Listenable.merge([ShareSession.revision, ShareSession.history]),
            builder: (context, _) {
              final list = ShareSession.items.reversed.toList();
              final failed = list.where((i) => i.outgoing && i.state == SessionItemState.failed).length;
              final sessionPaths = {for (final i in list) if (i.file != null) i.file!.path};
              final earlier = ShareSession.history.value.where((r) => !sessionPaths.contains(r.path)).take(50).toList();
              if (list.isEmpty && earlier.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.swap_vert_circle_outlined, size: 64, color: scheme.primary),
                        const SizedBox(height: 12),
                        Text('Nothing sent yet', style: theme.textTheme.titleLarge),
                        const SizedBox(height: 6),
                        Text(
                          peer == null
                              ? 'Connect again to send and receive.'
                              : 'Pick videos in "Pick media" or tap Browse files. '
                                  'Anything ${peer.name} sends shows up here and is saved automatically.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        if (peer != null) ...[
                          const SizedBox(height: 16),
                          FilledButton.tonalIcon(
                            onPressed: () => _tabs.animateTo(0),
                            icon: const Icon(Icons.video_library_rounded),
                            label: const Text('Pick media'),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                children: [
                  if (failed > 0 && peer != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      child: OutlinedButton.icon(
                        key: const ValueKey('session-retry-all'),
                        onPressed: ShareSession.retryAll,
                        icon: const Icon(Icons.refresh_rounded),
                        label: Text('Retry $failed failed'),
                      ),
                    ),
                  for (final it in list) ...[
                    _ItemTile(
                      item: it,
                      peerName: shown?.name ?? '',
                      canRetry: peer != null,
                      onOpen: _open,
                    ),
                    const SizedBox(height: 2),
                  ],
                  if (earlier.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 16, 8, 6),
                      child: Row(
                        children: [
                          Expanded(child: Text('Received earlier', style: theme.textTheme.titleSmall)),
                          TextButton(onPressed: ShareSession.clearHistory, child: const Text('Clear')),
                        ],
                      ),
                    ),
                    for (final r in earlier)
                      _HistoryTile(record: r, onOpen: () => _openPath(r.path, r.name)),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.color, required this.onColor, required this.icon, required this.text, this.busy = false, this.action});
  final Color color;
  final Color onColor;
  final IconData icon;
  final String text;
  final bool busy;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('session-state-banner'),
      color: color,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            if (busy)
              SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: onColor))
            else
              Icon(icon, color: onColor),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: TextStyle(color: onColor))),
            if (action != null) ...[const SizedBox(width: 8), action!],
          ],
        ),
      ),
    );
  }
}

/// "✓ Saved to Gallery" (Android videos/photos) or the folder it went to.
Widget _savedChip(BuildContext context, {required bool gallery, required String path}) {
  final scheme = Theme.of(context).colorScheme;
  final where = gallery
      ? 'Saved to Gallery'
      : Plat.isWindows
          ? 'Saved to ${File(path).parent.path.split(Platform.pathSeparator).last}'
          : 'Saved to Received';
  return Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle_rounded, size: 14, color: scheme.primary),
        const SizedBox(width: 4),
        Flexible(
          child: Text(where,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700)),
        ),
      ],
    ),
  );
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item, required this.peerName, required this.onOpen, required this.canRetry});
  final SessionItem item;
  final String peerName;
  final bool canRetry;
  final void Function(SessionItem) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final it = item;
    final failed = it.state == SessionItemState.failed;
    final done = it.state == SessionItemState.done;
    final status = switch (it.state) {
      SessionItemState.queued => it.autoRetries > 0 ? 'Waiting' : 'Queued',
      SessionItemState.sending => it.fraction == null ? 'Sending…' : 'Sending… ${(it.fraction! * 100).floor()}%',
      SessionItemState.receiving => it.fraction == null ? 'Receiving…' : 'Receiving… ${(it.fraction! * 100).floor()}%',
      SessionItemState.done => it.outgoing ? 'Sent' : 'Received',
      SessionItemState.failed => 'Failed',
    };
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: failed ? scheme.errorContainer : (done ? scheme.primaryContainer : scheme.secondaryContainer),
              child: Icon(
                done ? Icons.check_rounded : (it.outgoing ? Icons.north_east_rounded : Icons.south_west_rounded),
                size: 20,
                color: failed ? scheme.onErrorContainer : (done ? scheme.onPrimaryContainer : scheme.onSecondaryContainer),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    [
                      '${it.outgoing ? 'To' : 'From'} $peerName',
                      status,
                      if (it.size > 0) formatBytes(it.size),
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                  if (it.active || it.state == SessionItemState.queued) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: it.state == SessionItemState.queued ? 0 : it.fraction),
                  ],
                  if (done && !it.outgoing && it.file != null)
                    _savedChip(context, gallery: it.inGallery, path: it.file!.path)
                  else if (it.detail.isNotEmpty && !(done && it.outgoing && it.detail == 'Sent'))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        it.detail,
                        style: theme.textTheme.bodySmall?.copyWith(color: failed ? scheme.error : null),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            if (it.active && it.speed > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  '${(it.speed / (1024 * 1024)).toStringAsFixed(1)}\nMB/s',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, height: 1.1),
                ),
              ),
            if (done && !it.outgoing && it.file != null)
              FilledButton.tonal(
                onPressed: () => onOpen(it),
                child: Text(isVideoName(it.file!.path) ? 'Play' : 'Open'),
              )
            else if (failed && it.outgoing && canRetry && it.file != null) ...[
              FilledButton.tonalIcon(
                key: ValueKey('session-retry-${it.key}'),
                onPressed: () => ShareSession.retry(it),
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Retry'),
              ),
              IconButton(
                tooltip: 'Remove',
                onPressed: () => ShareSession.remove(it),
                icon: const Icon(Icons.close_rounded),
              ),
            ] else if (it.state == SessionItemState.queued || failed)
              IconButton(
                tooltip: 'Remove',
                onPressed: () => ShareSession.remove(it),
                icon: const Icon(Icons.close_rounded),
              ),
          ],
        ),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.record, required this.onOpen});
  final ReceivedRecord record;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final exists = record.exists;
    final d = record.at;
    final when = '${d.day}/${d.month} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      leading: Icon(isVideoName(record.path) ? Icons.movie_rounded : Icons.insert_drive_file_rounded),
      title: Text(record.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(['From ${record.from}', when, if (record.size > 0) formatBytes(record.size)].join(' · '),
              style: theme.textTheme.bodySmall),
          if (exists) _savedChip(context, gallery: record.inGallery, path: record.path) else Text('Moved or deleted', style: theme.textTheme.bodySmall),
        ],
      ),
      trailing: exists ? TextButton(onPressed: onOpen, child: Text(isVideoName(record.path) ? 'Play' : 'Open')) : null,
    );
  }
}
