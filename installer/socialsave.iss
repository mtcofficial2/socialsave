; SocialSave Windows setup.
; Build the app first (1.0.37+: local download engine, no hosted server):
;   flutter build windows --release --dart-define=SOCIALSAVE_LOCAL_ENGINE=true
;   powershell -ExecutionPolicy Bypass -File tool\fetch_engine.ps1
; (fetch_engine.ps1 builds backend\ as socialsave-engine.exe and stages it with
; yt-dlp, ffmpeg/ffprobe and deno in Release\engine\.)
; Then compile this script with Inno Setup (ISCC).

#define AppVersion "1.0.47"
#define SourceDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{7B2E9C14-6A41-4E8F-9C3D-1F5A8B0E6D27}
AppName=SocialSave
AppVersion={#AppVersion}
AppVerName=SocialSave {#AppVersion}
AppPublisher=SocialSave
AppPublisherURL=https://github.com/mtcofficial2/socialsave
AppSupportURL=https://github.com/mtcofficial2/socialsave/releases
DefaultDirName={autopf}\SocialSave
DefaultGroupName=SocialSave
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableWelcomePage=no
OutputDir=..\dist
OutputBaseFilename=SocialSave-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\SocialSave.exe
UninstallDisplayName=SocialSave
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no
MinVersion=10.0
VersionInfoVersion={#AppVersion}.0
VersionInfoCompany=SocialSave
VersionInfoProductName=SocialSave
VersionInfoDescription=SocialSave installer

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[UninstallDelete]
; yt-dlp updates and the engine log (the bundled engine is under {app}).
Type: filesandordirs; Name: "{localappdata}\SocialSave\engine"

[Icons]
Name: "{group}\SocialSave"; Filename: "{app}\SocialSave.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\SocialSave"; Filename: "{app}\SocialSave.exe"; WorkingDir: "{app}"

[Registry]
; Listed under Open with. Does not replace the default video player.
Root: HKCU; Subkey: "Software\Classes\SocialSave.Video"; ValueType: string; ValueName: ""; ValueData: "SocialSave"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\SocialSave.Video\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\SocialSave.exe"",0"
Root: HKCU; Subkey: "Software\Classes\SocialSave.Video\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\SocialSave.exe"" ""%1"""
Root: HKCU; Subkey: "Software\Classes\Applications\SocialSave.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "SocialSave"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\SocialSave.exe\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\SocialSave.exe"" ""%1"""
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\App Paths\SocialSave.exe"; ValueType: string; ValueName: ""; ValueData: "{app}\SocialSave.exe"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\App Paths\SocialSave.exe"; ValueType: string; ValueName: "Path"; ValueData: "{app}"
Root: HKCU; Subkey: "Software\Classes\Applications\SocialSave.exe\SupportedTypes"; ValueType: string; ValueName: ".mp4"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\Applications\SocialSave.exe\SupportedTypes"; ValueType: string; ValueName: ".mkv"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\Applications\SocialSave.exe\SupportedTypes"; ValueType: string; ValueName: ".webm"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\Applications\SocialSave.exe\SupportedTypes"; ValueType: string; ValueName: ".mov"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\Applications\SocialSave.exe\SupportedTypes"; ValueType: string; ValueName: ".m4v"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\SystemFileAssociations\video\OpenWithProgids"; ValueType: none; ValueName: "SocialSave.Video"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.mp4\OpenWithProgids"; ValueType: none; ValueName: "SocialSave.Video"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.mkv\OpenWithProgids"; ValueType: none; ValueName: "SocialSave.Video"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.webm\OpenWithProgids"; ValueType: none; ValueName: "SocialSave.Video"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.mov\OpenWithProgids"; ValueType: none; ValueName: "SocialSave.Video"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.m4v\OpenWithProgids"; ValueType: none; ValueName: "SocialSave.Video"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\SystemFileAssociations\.mp4\OpenWithProgids"; ValueType: none; ValueName: "SocialSave.Video"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\SystemFileAssociations\.mkv\OpenWithProgids"; ValueType: none; ValueName: "SocialSave.Video"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\SystemFileAssociations\.webm\OpenWithProgids"; ValueType: none; ValueName: "SocialSave.Video"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\SystemFileAssociations\.mov\OpenWithProgids"; ValueType: none; ValueName: "SocialSave.Video"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\SystemFileAssociations\.m4v\OpenWithProgids"; ValueType: none; ValueName: "SocialSave.Video"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\SocialSave.exe"; Description: "Open SocialSave"; Flags: nowait postinstall skipifsilent
