; KO影视 Windows 安装包（Inno Setup 6）
; 由 scripts/make-win-installer.ps1 传入定义：
;   MyAppVersion, MySourceDir, MyOutputDir, MyOutputBase, MyArch (x64|arm64)

#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif
#ifndef MySourceDir
  #define MySourceDir "..\..\dist\KOTV-windows-x64"
#endif
#ifndef MyOutputDir
  #define MyOutputDir "..\.."
#endif
#ifndef MyOutputBase
  #define MyOutputBase "KOTV-win-amd64-setup"
#endif
#ifndef MyArch
  #define MyArch "x64"
#endif

#define MyAppName "KO影视"
#define MyAppPublisher "KOTV"
#define MyAppExeName "KOTV.exe"
#define MyAppURL "https://github.com/zhangbo8418/KOTV"

#if MyArch == "arm64"
  #define MyAppId "{{A8E3C2B1-4D5F-6A70-8B9C-0D1E2F3A4B5C}"
#else
  #define MyAppId "{{7F2E9D41-6C8A-4B3E-9F1D-5A0C8E7B2D64}"
#endif

[Setup]
AppId={#MyAppId}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#MyOutputDir}
OutputBaseFilename={#MyOutputBase}
SetupIconFile=..\..\resources\icons\KOTV.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
CloseApplications=yes
RestartApplications=no
#if MyArch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=6.1sp1
#endif

[Languages]
; Chocolatey Inno Setup 通常不带简体中文包，使用仓库内语言文件。
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加图标:"; Flags: checkedonce

[Files]
Source: "{#MySourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent
