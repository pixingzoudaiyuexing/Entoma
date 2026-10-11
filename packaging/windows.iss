#define AppName "Entoma"
#define AppVersion "0.1.0"
[Setup]
AppId={{31294A2A-3E92-4AB0-A2E5-7D016DCBE730}
AppName={#AppName}
AppVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\Entoma
DefaultGroupName=Entoma
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=Entoma-0.1.0-windows-x64-setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\Entoma.exe
[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{group}\Entoma"; Filename: "{app}\Entoma.exe"
Name: "{userdesktop}\Entoma"; Filename: "{app}\Entoma.exe"; Tasks: desktopicon
[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked
[Run]
Filename: "{app}\Entoma.exe"; Description: "Launch Entoma"; Flags: nowait postinstall skipifsilent
