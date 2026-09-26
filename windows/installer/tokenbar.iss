; TokenBar Windows 安装包脚本（Inno Setup 6.3+）
;
; CI 调用（release.yml 的 build-windows 矩阵任务）：
;   ISCC.exe /DAppVersion=x.y.z /DArch=x64|arm64 /DSourceDir="<绝对路径>\publish" tokenbar.iss
;   注意：Source 路径相对 .iss 脚本目录解析，非工作目录——本地手动调用请传绝对路径。
; 本地调用（需先 dotnet publish 到 windows\publish 目录，见 windows\README.md）：
;   ISCC.exe /DAppVersion=1.4.0 /DArch=x64 /DSourceDir="D:\Work\TokenBar\windows\publish" tokenbar.iss

#ifndef AppVersion
#define AppVersion "0.0.0"
#endif

#ifndef Arch
#define Arch "x64"
#endif

#ifndef SourceDir
#define SourceDir "..\publish"
#endif

; 设计约定：
;   - 按用户安装（PrivilegesRequired=lowest，装进 {localappdata}\Programs\TokenBar），
;     与 windows/install.ps1 的安装目录一致，无需管理员权限、不弹 UAC
;   - 中文为缺省向导语言（ChineseSimplified.isl 随仓库分发，来自 issrc 官方语言包）

#define AppName "TokenBar"
#define AppPublisher "TokenBar Team"
#define AppExeName "TokenBar.exe"
#define AppDesc "模型额度监控 / Model Quota Monitor"

#if Arch == "arm64"
#define ArchAllowed "arm64"
#else
#define ArchAllowed "x64compatible"
#endif

[Setup]
AppId={{AFA951B5-6916-4DC9-891C-05DA1B6DF299}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppComments={#AppDesc}
VersionInfoVersion={#AppVersion}
VersionInfoDescription={#AppName} {#AppVersion} ({#Arch}) 安装包
; 按用户安装：无需管理员权限
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\{#AppName}
DisableProgramGroupPage=yes
; 换架构升级时清掉旧目录里不存在的文件；卸载时不删用户数据目录
ArchitecturesAllowed={#ArchAllowed}
CloseApplications=force
RestartApplications=no
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
OutputDir=Output
OutputBaseFilename=TokenBar-v{#AppVersion}-win-{#Arch}-setup
UninstallDisplayName={#AppName} - {#AppDesc}
UninstallDisplayIcon={app}\{#AppExeName}

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 发布目录整体安装：TokenBar.exe + 同目录原生 DLL（wpfgfx_cor3.dll 等），
; 原生库不经手 %TEMP%，避免被清理工具删除后 WPF 渲染崩溃（DllNotFoundException）
Source: "{#SourceDir}\*"; Excludes: "*.pdb"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Comment: "{#AppDesc}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Comment: "{#AppDesc}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
