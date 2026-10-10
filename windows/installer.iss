; Inno Setup script for the Windows installer. Built by CI:
;   ISCC.exe /DAppVersion=0.1.1 windows\installer.iss
; after `flutter build windows --release`. Output: dist\Marsa-windows-setup.exe

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
; Never change AppId: it is how an update finds the previous install.
AppId={{6F0B2C4E-9C1D-4B7A-8E55-3A1D0F4C7B21}
AppName=Marsa
AppVersion={#AppVersion}
AppPublisher=Marsa contributors
AppPublisherURL=https://github.com/AdnanBolifa/marsa
DefaultDirName={autopf}\Marsa
DefaultGroupName=Marsa
DisableProgramGroupPage=yes
; Installs for the current user, so no administrator prompt is needed.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile=..\LICENSE
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\marsa.exe
OutputDir=..\dist
OutputBaseFilename=Marsa-windows-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Marsa"; Filename: "{app}\marsa.exe"
Name: "{autodesktop}\Marsa"; Filename: "{app}\marsa.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\marsa.exe"; Description: "{cm:LaunchProgram,Marsa}"; Flags: nowait postinstall skipifsilent
