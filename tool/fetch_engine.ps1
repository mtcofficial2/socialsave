<#
  SocialSave for Windows: builds and stages the local download engine.

  Output: build\windows\x64\runner\Release\engine\
    socialsave-engine.exe   the Go backend (backend\), bound to 127.0.0.1
    yt-dlp.exe + yt-dlp.version
    ffmpeg.exe, ffprobe.exe (+ DLLs)   yt-dlp/FFmpeg-Builds win64 gpl-shared
    deno.exe                JS runtime yt-dlp uses for YouTube
  The app starts the engine itself and keeps yt-dlp updated daily into
  %LOCALAPPDATA%\SocialSave\engine. Needs Go and internet. Re-run any time.
#>
param(
  [string]$Release = (Join-Path $PSScriptRoot '..\build\windows\x64\runner\Release'),
  [string]$Cache = (Join-Path $env:TEMP 'socialsave-engine-cache')
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$engine = Join-Path $Release 'engine'
New-Item -ItemType Directory -Force $engine, $Cache | Out-Null

function Get-File($url, $dest) {
  if (-not (Test-Path $dest)) {
    Write-Host "Downloading $url"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile "$dest.part"
    Move-Item -Force "$dest.part" $dest
  }
}

# 1. Engine (the same API the Android app uses on the hosted server).
Push-Location (Join-Path $root 'backend')
try {
  $env:GOOS = 'windows'; $env:GOARCH = 'amd64'; $env:CGO_ENABLED = '0'
  go build -trimpath -ldflags '-s -w -H=windowsgui' -o (Join-Path $engine 'socialsave-engine.exe') ./cmd/api
  if ($LASTEXITCODE -ne 0) { throw 'go build failed' }
} finally {
  Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
  Pop-Location
}

# 2. yt-dlp (checked against the release's SHA2-256SUMS).
$ytdlp = Join-Path $Cache 'yt-dlp.exe'
Remove-Item $ytdlp -ErrorAction SilentlyContinue
Get-File 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe' $ytdlp
$sums = (Invoke-WebRequest -UseBasicParsing 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS').Content
$want = ($sums -split "`n" | Where-Object { $_ -match '\syt-dlp\.exe$' } | ForEach-Object { ($_ -split '\s+')[0] })
$have = (Get-FileHash $ytdlp -Algorithm SHA256).Hash.ToLower()
if ($want -and $want.ToLower() -ne $have) { throw "yt-dlp.exe checksum mismatch" }
Copy-Item -Force $ytdlp $engine
(& (Join-Path $engine 'yt-dlp.exe') --version).Trim() | Set-Content -NoNewline (Join-Path $engine 'yt-dlp.version')

# 3. ffmpeg + ffprobe (shared build: smaller in total than two static exes).
$ffZip = Join-Path $Cache 'ffmpeg-win64-gpl-shared.zip'
Get-File 'https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl-shared.zip' $ffZip
$ffDir = Join-Path $Cache 'ff'
if (-not (Test-Path $ffDir)) { Expand-Archive -Force $ffZip $ffDir }
$bin = Get-ChildItem $ffDir -Recurse -Filter ffmpeg.exe | Select-Object -First 1 | ForEach-Object { $_.DirectoryName }
Copy-Item -Force (Join-Path $bin 'ffmpeg.exe'), (Join-Path $bin 'ffprobe.exe') $engine
Get-ChildItem $bin -Filter *.dll | Copy-Item -Destination $engine -Force

# 4. deno.
$denoZip = Join-Path $Cache 'deno.zip'
Get-File 'https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip' $denoZip
Expand-Archive -Force $denoZip $engine

Write-Host "Engine staged in $engine"
Get-ChildItem $engine | Select-Object Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } } | Format-Table -AutoSize
