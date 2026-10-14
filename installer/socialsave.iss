; SocialSave Windows setup.
; Build the app first:
;   flutter build windows --release --dart-define=API_BASE_URL=https://socialsave-api-p2tm.onrender.com
; Then compile this script with Inno Setup (ISCC).

#define AppVersion "1.0.19"
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

[Icons]
Name: "{group}\SocialSave"; Filename: "{app}\SocialSave.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\SocialSave"; Filename: "{app}\SocialSave.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\SocialSave.exe"; Description: "Open SocialSave"; Flags: nowait postinstall skipifsilent
