#define MyAppName "GatoMix"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Gabriel Calle"
#define MyAppExeName "gatomix_player.exe"
#define BuildPath "C:\Python\gatomix_player\build\windows\x64\runner\Release"

[Setup]
; ID único para que Windows sepa cómo actualizar o desinstalar la app
AppId={{9A2B3C4D-5E6F-7A8B-9C0D-1E2F3A4B5C6D}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DisableProgramGroupPage=yes
; El instalador final aparecerá en esta carpeta
OutputDir=C:\Python\gatomix_player\Instalador
OutputBaseFilename=GatoMix_Setup_v1.0.0
Compression=lzma2/ultra
SolidCompression=yes
WizardStyle=modern
SetupIconFile=windows\runner\resources\app_icon.ico

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Copia el ejecutable, FFprobe, todas las DLLs y la carpeta /data recursivamente
Source: "{#BuildPath}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent