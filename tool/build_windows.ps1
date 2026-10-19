<#
  SocialSave for Windows: one command for a release build.
    powershell -ExecutionPolicy Bypass -File tool\build_windows.ps1
  1. flutter build windows --release WITH --dart-define=SOCIALSAVE_LOCAL_ENGINE=true
     (1.0.41-1.0.43 were built without it and talked to the hosted server,
     where YouTube's bot check showed up as "private video").
  2. tool\fetch_engine.ps1 (Go engine, latest yt-dlp, ffmpeg, deno).
  3. Inno Setup installer -> dist\SocialSave-Setup-<ver>.exe
  4. Portable zip -> dist\SocialSave-Windows-<ver>-portable.zip
  Nothing is uploaded.
#>
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $root
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { $env:PATH = "C:\src\flutter\bin;$env:PATH" }
$ver = ((Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value)
Write-Host "Building SocialSave $ver for Windows"
flutter build windows --release --dart-define=SOCIALSAVE_LOCAL_ENGINE=true
if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }
& (Join-Path $PSScriptRoot 'fetch_engine.ps1')
$release = Join-Path $root 'build\windows\x64\runner\Release'
$iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 (ISCC.exe) not found' }
& $iscc (Join-Path $root 'installer\socialsave.iss')
if ($LASTEXITCODE -ne 0) { throw 'ISCC failed' }
$zip = Join-Path $root "dist\SocialSave-Windows-$ver-portable.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $release '*') -DestinationPath $zip -CompressionLevel Optimal
Get-ChildItem (Join-Path $root 'dist') -Filter "*$ver*" | Format-Table Name, Length -AutoSize
