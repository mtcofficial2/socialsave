import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Windows Mobile hotspot for "Fast share" from a PC (Xender-style): the PC
/// opens a Wi-Fi hotspot named SocialSave-1234 with an 8-digit password and
/// shows the same QR the phones use, so a phone joins the PC directly.
///
/// Uses the Windows Mobile hotspot API
/// (Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager)
/// through a small Windows PowerShell bridge. The user's own Mobile hotspot
/// name/password/band are saved first and put back when SocialSave stops it.
/// If Mobile hotspot was already on (the user's own), it is reused and left
/// on afterwards.
class PcHotspot {
  PcHotspot._();

  static String get _dir => p.join(Directory.systemTemp.path, 'socialsave_hotspot');
  static String get _script => p.join(_dir, 'hotspot.ps1');
  static String get _state => p.join(_dir, 'saved.json');

  static Future<Map<String, dynamic>> run(String action, {Map<String, String> args = const {}}) async {
    try {
      await Directory(_dir).create(recursive: true);
      await File(_script).writeAsString(_ps, flush: true);
      final res = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        _script,
        '-Action',
        action,
        '-StateFile',
        _state,
        for (final e in args.entries) ...['-${e.key}', e.value],
      ]).timeout(const Duration(seconds: 60));
      final out = '${res.stdout}';
      final line = out.split(RegExp(r'\r?\n')).lastWhere((l) => l.trim().startsWith('{'), orElse: () => '');
      if (line.isEmpty) {
        debugPrint('[pc-hotspot] $action: no answer. ${res.stderr}');
        return {'ok': false, 'error': 'Windows did not answer (${'${res.stderr}'.trim().split('\n').first}).'};
      }
      final j = jsonDecode(line) as Map<String, dynamic>;
      debugPrint('[pc-hotspot] $action -> $line');
      return j;
    } catch (e) {
      return {'ok': false, 'error': 'Could not control Mobile hotspot: $e'};
    }
  }

  /// A user-facing reason the PC cannot host, or null when it can.
  static Future<String?> prepare() async {
    final s = await run('status');
    return blockMessage(s);
  }

  static String? blockMessage(Map<String, dynamic> s) {
    if (s['ok'] != true) return '${s['error'] ?? 'Mobile hotspot is not available on this PC.'}';
    if (s['internet'] != true) {
      return 'Windows only starts Mobile hotspot while this PC is online (Wi-Fi or Ethernet with internet). '
          'Connect it to the internet, or send over the same Wi-Fi instead.';
    }
    return switch ('${s['capability']}') {
      'Enabled' => null,
      'DisabledByGroupPolicy' => 'Mobile hotspot is turned off by your organisation\'s policy on this PC. Send over the same Wi-Fi instead.',
      'DisabledByHardwareLimitation' => 'This PC\'s Wi-Fi adapter can\'t host a hotspot. Send over the same Wi-Fi instead.',
      'DisabledByOperator' => 'Your network operator blocks Mobile hotspot on this connection. Send over the same Wi-Fi instead.',
      'DisabledBySku' => 'This edition of Windows doesn\'t include Mobile hotspot. Send over the same Wi-Fi instead.',
      'DisabledBySystemCapability' => 'Windows has Mobile hotspot switched off for apps. Turn it on in Settings › Privacy › Radios / Mobile hotspot, or send over the same Wi-Fi.',
      final other => 'Mobile hotspot is not available on this PC ($other). Send over the same Wi-Fi instead.',
    };
  }

  /// Starts Mobile hotspot. [band] is 'auto', '5' or '2.4'.
  static Future<Map<String, dynamic>> start({required String band, String? ssid, String? password}) async {
    final r = await run('start', args: {
      'Band': band,
      if (ssid != null && ssid.isNotEmpty) 'Ssid': ssid,
      if (password != null && password.length >= 8) 'Pass': password,
    });
    if (r['ok'] == true && r['reused'] != true) _startedHere = true;
    return r;
  }

  /// SocialSave turned Mobile hotspot on in this run (so it turns it off).
  static bool _startedHere = false;

  static Future<void> stop() async {
    await run('stop', args: {if (_startedHere) 'Force': '1'});
    _startedHere = false;
  }

  static Future<bool> isRunning() async => (await run('status'))['state'] == 'On';

  /// The PC's address on its hotspot (Windows uses 192.168.137.1).
  static Future<String?> address() async {
    for (var i = 0; i < 20; i++) {
      try {
        final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
        for (final ni in list) {
          for (final a in ni.addresses) {
            if (a.address.startsWith('192.168.137.')) return a.address;
          }
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return null;
  }

  static const _ps = r'''
param([string]$Action = 'status', [string]$StateFile = '', [string]$Band = 'auto', [string]$Ssid = '', [string]$Pass = '', [string]$Force = '0')
$ErrorActionPreference = 'Stop'
function Out-Json($o) { Write-Output ($o | ConvertTo-Json -Compress -Depth 4) }
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $asTaskOp = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
  function Await($op, [Type]$type) { $t = $asTaskOp.MakeGenericMethod($type).Invoke($null, @($op)); $t.Wait(-1) | Out-Null; $t.Result }
  $asTaskAct = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
  function AwaitAction($op) { $t = $asTaskAct.Invoke($null, @($op)); $t.Wait(-1) | Out-Null }
  [void][Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]
  [void][Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime]
  $profile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
  if ($null -eq $profile) { Out-Json @{ ok = $true; internet = $false; state = 'Off'; capability = 'NoInternet' }; exit 0 }
  $cap = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::GetTetheringCapabilityFromConnectionProfile($profile)
  if ("$cap" -ne 'Enabled') { Out-Json @{ ok = $true; internet = $true; state = 'Off'; capability = "$cap" }; exit 0 }
  $tm = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($profile)
  $cfg = $tm.GetCurrentAccessPointConfiguration()
  $bandNow = $null; $has5 = $null; $has24 = $null
  try { $bandNow = "$($cfg.Band)" } catch {}
  try { $has5 = $cfg.IsBandSupported([Windows.Networking.NetworkOperators.TetheringWiFiBand]::FiveGigahertz) } catch {}
  try { $has24 = $cfg.IsBandSupported([Windows.Networking.NetworkOperators.TetheringWiFiBand]::TwoPointFourGigahertz) } catch {}
  $state = "$($tm.TetheringOperationalState)"
  $base = @{ ok = $true; internet = $true; capability = 'Enabled'; state = $state; clients = $tm.ClientCount; band = $bandNow; has5 = $has5; has24 = $has24; via = $profile.ProfileName }
  switch ($Action) {
    'status' { $base.ssid = $cfg.Ssid; Out-Json $base }
    'start' {
      if ($state -eq 'On') {
        # The user's own hotspot is already on: reuse it and leave it on later.
        if (-not (Test-Path $StateFile)) {
          $base.ssid = $cfg.Ssid; $base.password = $cfg.Passphrase; $base.reused = $true; $base.custom = $false
          Out-Json $base; exit 0
        }
        $base.ssid = $cfg.Ssid; $base.password = $cfg.Passphrase; $base.custom = $true
        Out-Json $base; exit 0
      }
      if (-not (Test-Path $StateFile)) {
        @{ ssid = $cfg.Ssid; pass = $cfg.Passphrase; band = $bandNow } | ConvertTo-Json -Compress | Set-Content -Path $StateFile -Encoding UTF8
      }
      $rnd = New-Object System.Random
      if ($Ssid -eq '') { $Ssid = 'SocialSave-' + (-join (1..4 | ForEach-Object { $rnd.Next(0, 10) })) }
      if ($Pass.Length -lt 8) { $Pass = -join (1..8 | ForEach-Object { $rnd.Next(0, 10) }) }
      $cfg.Ssid = $Ssid
      $cfg.Passphrase = $Pass
      $note = ''
      $B = [Windows.Networking.NetworkOperators.TetheringWiFiBand]
      $TR = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult]
      # Auto lets Windows pick (it must share the radio with this PC's own Wi-Fi).
      $bands = @('Auto')
      if ($Band -eq '5') { if ($has5) { $bands = @('FiveGigahertz', 'Auto') } else { $note = "This PC's Wi-Fi can't host on 5 GHz; using its default band." } }
      if ($Band -eq '2.4') { $bands = @('TwoPointFourGigahertz', 'Auto') }
      $ok = $false; $r = $null
      foreach ($wb in $bands) {
        try { $cfg.Band = $B::$wb } catch { if ($wb -ne 'Auto') { $note = "This version of Windows doesn't let apps choose the hotspot band." } }
        AwaitAction ($tm.ConfigureAccessPointAsync($cfg))
        $r = Await ($tm.StartTetheringAsync()) $TR
        $ok = ("$($r.Status)" -eq 'Success')
        if (-not $ok) { for ($i = 0; $i -lt 12; $i++) { Start-Sleep -Milliseconds 700; if ("$($tm.TetheringOperationalState)" -eq 'On') { $ok = $true; break } } }
        if ($ok) { break }
        if ($wb -ne 'Auto') { $note = "Windows refused that band (it keeps the hotspot on the band its own Wi-Fi uses); using the default band." }
        if ("$($tm.TetheringOperationalState)" -ne 'Off') { try { [void](Await ($tm.StopTetheringAsync()) $TR) } catch {}; Start-Sleep -Seconds 1 }
      }
      if (-not $ok) {
        $msg = "$($r.AdditionalErrorMessage)"
        if ("$($tm.TetheringOperationalState)" -ne 'Off') { try { [void](Await ($tm.StopTetheringAsync()) $TR) } catch {} }
        try { $saved = Get-Content $StateFile -Raw | ConvertFrom-Json; $cfg.Ssid = $saved.ssid; $cfg.Passphrase = $saved.pass; AwaitAction ($tm.ConfigureAccessPointAsync($cfg)) } catch {}
        Remove-Item $StateFile -ErrorAction SilentlyContinue
        $why = switch ("$($r.Status)") { 'WiFiDeviceOff' { "Turn on this PC's Wi-Fi and try again." } 'MobileBroadbandDeviceOff' { 'The connection to share is off.' } 'EntitlementCheckFailure' { 'Your network operator refused the hotspot.' } 'OperationInProgress' { 'Windows is still switching the hotspot; try again in a moment.' } default { '' } }
        Out-Json @{ ok = $false; status = "$($r.Status)"; error = "Mobile hotspot did not start ($($r.Status)). $why $msg".Trim() }; exit 0
      }
      $cfg2 = $tm.GetCurrentAccessPointConfiguration()
      $b2 = $null; try { $b2 = "$($cfg2.Band)" } catch {}
      Out-Json @{ ok = $true; internet = $true; capability = 'Enabled'; state = "$($tm.TetheringOperationalState)"; ssid = $cfg2.Ssid; password = $cfg2.Passphrase; band = $b2; has5 = $has5; custom = $true; note = $note; via = $profile.ProfileName }
    }
    'stop' {
      if (-not (Test-Path $StateFile) -and $Force -ne '1') { $base.stopped = $false; $base.note = 'not started by SocialSave'; Out-Json $base; exit 0 }
      if ($state -ne 'Off') { $r = Await ($tm.StopTetheringAsync()) ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult]) }
      if (Test-Path $StateFile) { try {
        $saved = Get-Content $StateFile -Raw | ConvertFrom-Json
        $cfg = $tm.GetCurrentAccessPointConfiguration()
        if ($saved.ssid) { $cfg.Ssid = $saved.ssid }
        if ($saved.pass) { $cfg.Passphrase = $saved.pass }
        if ($saved.band) { try { $cfg.Band = [Windows.Networking.NetworkOperators.TetheringWiFiBand]::$($saved.band) } catch {} }
        AwaitAction ($tm.ConfigureAccessPointAsync($cfg))
      } catch {} }
      Remove-Item $StateFile -ErrorAction SilentlyContinue
      Out-Json @{ ok = $true; stopped = $true; state = "$($tm.TetheringOperationalState)" }
    }
  }
} catch {
  Out-Json @{ ok = $false; error = "Mobile hotspot error: $($_.Exception.Message)" }
}
''';
}
