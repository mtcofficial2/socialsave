import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:social_save/core/platform/plat.dart';

/// Windows Firewall: is SocialSave allowed to accept connections from the
/// other device (inbound TCP, private and public networks)? The PC's mobile
/// hotspot network is usually "public", so a private-only rule isn't enough.
///
/// 1.0.36: checked without admin rights; the rule is added only after the
/// user agrees in the app, through Windows' own administrator prompt.
class FirewallCheck {
  FirewallCheck._();

  /// TCP ports SocialSave listens on (pairing 47321, drop 47323, inbox
  /// 47325 and the spare ports it falls back to).
  static const tcpPorts = '47321-47330';

  /// UDP discovery (47322) and nearby beacons (47324).
  static const udpPorts = '47322,47324';

  /// null = not checked yet / not Windows.
  static final ValueNotifier<FirewallStatus?> status = ValueNotifier<FirewallStatus?>(null);
  static Future<FirewallStatus?>? _checking;

  static String get exe => Platform.resolvedExecutable;

  static String _q(String s) => "'${s.replaceAll("'", "''")}'";

  static Future<FirewallStatus?> check({bool fresh = false}) {
    if (!Plat.isWindows) return Future.value(null);
    if (!fresh && status.value != null) return Future.value(status.value);
    return _checking ??= _check().whenComplete(() => _checking = null);
  }

  static Future<FirewallStatus?> _check() async {
    final script = '''
\$exe = ${_q(exe)}
\$rules = Get-NetFirewallApplicationFilter -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
  Where-Object { \$_.Program -ieq \$exe } | Get-NetFirewallRule -ErrorAction SilentlyContinue |
  Where-Object { \$_.Direction -eq 'Inbound' -and \$_.Enabled -eq 'True' }
\$prof = @()
foreach (\$r in @(\$rules | Where-Object { \$_.Action -eq 'Allow' })) {
  \$pf = \$r | Get-NetFirewallPortFilter
  if (\$pf.Protocol -eq 'Any' -or \$pf.Protocol -eq 'TCP') { \$prof += \$r.Profile.ToString() }
}
\$block = @(\$rules | Where-Object { \$_.Action -eq 'Block' }).Count
"ALLOW=" + (\$prof -join ';')
"BLOCK=" + \$block
''';
    try {
      final res = await Process.run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script])
          .timeout(const Duration(seconds: 60));
      final out = '${res.stdout}';
      final allow = RegExp(r'ALLOW=(.*)').firstMatch(out)?.group(1)?.trim() ?? '';
      final block = int.tryParse(RegExp(r'BLOCK=(\d+)').firstMatch(out)?.group(1) ?? '') ?? 0;
      final any = allow.contains('Any');
      final s = FirewallStatus(
        privateOk: any || allow.contains('Private'),
        publicOk: any || allow.contains('Public'),
        blocked: block > 0,
      );
      debugPrint('[firewall] $exe allow="$allow" block=$block -> ${s.ok ? 'ok' : 'needs a rule'}');
      status.value = s;
      return s;
    } catch (e) {
      debugPrint('[firewall] check failed: $e');
      return null;
    }
  }

  /// Adds the inbound rules through Windows' administrator prompt (UAC).
  /// Returns null on success, otherwise why not.
  static Future<String?> allow() async {
    if (!Plat.isWindows) return null;
    final inner = '''
\$exe = ${_q(exe)}
\$n = 'SocialSave inbound (' + \$exe + ')'
Get-NetFirewallRule -DisplayName \$n -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Get-NetFirewallRule -DisplayName (\$n + ' UDP') -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | Where-Object { \$_.Program -ieq \$exe } |
  Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { \$_.Direction -eq 'Inbound' -and \$_.Action -eq 'Block' } |
  Remove-NetFirewallRule
New-NetFirewallRule -DisplayName \$n -Direction Inbound -Action Allow -Program \$exe -Protocol TCP -LocalPort $tcpPorts -Profile Private,Public | Out-Null
New-NetFirewallRule -DisplayName (\$n + ' UDP') -Direction Inbound -Action Allow -Program \$exe -Protocol UDP -LocalPort $udpPorts -Profile Private,Public | Out-Null
''';
    final encoded = base64.encode(_utf16le(inner));
    final outer = '''
try {
  \$p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ArgumentList '-NoProfile','-EncodedCommand','$encoded'
  exit \$p.ExitCode
} catch { exit 5 }
''';
    try {
      final res = await Process.run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', outer])
          .timeout(const Duration(minutes: 3));
      debugPrint('[firewall] allow exit=${res.exitCode}');
      if (res.exitCode == 5) return 'Windows did not get administrator permission, so nothing changed.';
      final s = await check(fresh: true);
      if (s != null && s.ok) return null;
      return res.exitCode == 0 ? 'The rule was added but Windows still reports it as blocked.' : 'Could not add the rule (code ${res.exitCode}).';
    } catch (e) {
      return 'Could not add the rule: $e';
    }
  }

  static List<int> _utf16le(String s) {
    final out = <int>[];
    for (final c in s.codeUnits) {
      out
        ..add(c & 0xff)
        ..add(c >> 8);
    }
    return out;
  }
}

class FirewallStatus {
  const FirewallStatus({required this.privateOk, required this.publicOk, required this.blocked});
  final bool privateOk;
  final bool publicOk;
  final bool blocked;
  bool get ok => privateOk && publicOk && !blocked;
}

/// A clear in-app prompt (Windows only, shown only when a rule is missing):
/// explains the problem and asks before Windows' administrator prompt.
class FirewallPrompt extends StatefulWidget {
  const FirewallPrompt({super.key, this.compact = false});
  final bool compact;

  @override
  State<FirewallPrompt> createState() => _FirewallPromptState();
}

class _FirewallPromptState extends State<FirewallPrompt> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (Plat.isWindows) unawaited(FirewallCheck.check());
  }

  Future<void> _allow() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.shield_rounded),
        title: const Text('Allow SocialSave through Windows Firewall?'),
        content: const Text(
          'The other device needs to connect to this PC to send files back and to stay connected. '
          'SocialSave will add an inbound rule for SocialSave.exe only (private and public networks, '
          'TCP ports ${FirewallCheck.tcpPorts}), and remove any rule that blocks it.\n\n'
          'Windows will ask for administrator permission next.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
          FilledButton.icon(
            key: const ValueKey('firewall-allow-confirm'),
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.admin_panel_settings_rounded),
            label: const Text('Continue'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => _busy = true);
    final err = await FirewallCheck.allow();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(err ?? 'SocialSave is allowed through Windows Firewall.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (!Plat.isWindows) return const SizedBox.shrink();
    return ValueListenableBuilder<FirewallStatus?>(
      valueListenable: FirewallCheck.status,
      builder: (context, s, _) {
        if (s == null || s.ok) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final what = s.blocked
            ? 'Windows Firewall blocks SocialSave'
            : !s.publicOk && s.privateOk
                ? 'Windows Firewall allows SocialSave on private networks only (the hotspot is public)'
                : 'Windows Firewall may block the other device';
        return Padding(
          padding: EdgeInsets.symmetric(vertical: widget.compact ? 4 : 8),
          child: Material(
            key: const ValueKey('firewall-prompt'),
            color: scheme.errorContainer,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(
                children: [
                  Icon(Icons.shield_outlined, color: scheme.onErrorContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '$what. Allow it so phones can connect to this PC.',
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ),
                  const SizedBox(width: 6),
                  FilledButton.tonal(
                    key: const ValueKey('firewall-allow'),
                    onPressed: _busy ? null : _allow,
                    child: _busy
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Allow'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
