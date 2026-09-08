# TokenBar for Windows

**TokenBar - 模型额度监控 / Model Quota Monitor** (Windows Client)

TokenBar Windows 客户端采用原生的 **.NET 8 / C# WPF** 架构构建，专为 Windows 10 与 Windows 11 打造。具备系统托盘无缝集成、浮窗预览、多模型厂商统一授权与速率监控能力。

---

## 🛠️ 环境要求 (Prerequisites)

- **操作系统**: Windows 10 (1809 及以上) 或 Windows 11
- **运行时 / SDK**: [.NET 8.0 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) 或更高版本
- **开发工具 (推荐)**: Visual Studio 2022 (安装 ".NET 桌面开发" 工作负荷) 或 VS Code (搭配 C# Dev Kit 插件)

---

## 🚀 快速构建与运行 (Build & Run)

### 1. 运行调试
在 `windows/` 目录下打开 PowerShell 或 CMD 执行：

```bash
# 恢复依赖并构建运行
dotnet run --project src/TokenBar/TokenBar.csproj
```

### 2. 发布为独立单文件程序 (Self-contained Single File)

```bash
dotnet publish src/TokenBar/TokenBar.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o ./publish
```

发布后的 `TokenBar.exe` 将输出到 `./publish` 目录中，目标机器无需安装 .NET 环境。

> ⚠️ **必须使用上面的自包含单文件参数**。安装脚本只会复制一个 `TokenBar.exe`，
> 如果漏掉 `--self-contained true -p:PublishSingleFile=true`（框架依赖发布产物是
> 一个小 exe + 一堆 DLL），安装后启动会直接报
> "The application to execute does not exist: TokenBar.dll"。

---

## 📦 安装与升级 (Install & Upgrade)

日常自用/升级推荐使用仓库自带的一键安装脚本（在 `windows/` 目录执行）：

```powershell
dotnet publish src/TokenBar/TokenBar.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o publish
powershell -ExecutionPolicy Bypass -File install.ps1
```

`install.ps1` 会自动完成：

1. **停止正在运行的 TokenBar 实例**；
2. 将 `publish\TokenBar.exe` 复制到 `%LOCALAPPDATA%\Programs\TokenBar\`；
3. 创建开始菜单与桌面快捷方式，并注册 Win+R 的 `TokenBar` 运行别名。

安装完成后从开始菜单或安装目录启动即可。**请始终从安装目录运行安装版**，
避免和调试版进程混淆。

---

## 🧪 实机 GUI 测试工具 (tools/gui)

托盘像素区域的自动化点击对多数 UIA 工具不可达，仓库提供两个 PowerShell 辅助脚本：

- `tools/gui/tray-rightclick.ps1` — `SetCursorPos` + `mouse_event` P/Invoke，
  分小步移动光标到托盘图标并点击（NotifyIcon 只有光标真实移动才触发事件）；
- `tools/gui/list-menuitems.ps1` — 通过 UI Automation 枚举当前弹出的菜单项及坐标。

> 注：高 DPI（如 150%）下截图坐标 × DPI 缩放系数 = 物理坐标，使用时注意换算。

---

## 📂 项目结构说明

```
windows/
├── TokenBar.sln                  # Visual Studio 解决方案
├── README.md                     # 本说明文档
├── install.ps1                   # 一键安装/升级脚本（复制单文件 exe + 快捷方式）
├── tools/
│   └── gui/                      # 托盘实机测试辅助脚本 (PowerShell)
└── src/
    └── TokenBar/
        ├── TokenBar.csproj       # WPF 托盘应用项目文件
        ├── App.xaml / .cs        # 应用入口与生命周期管理
        ├── Tray/
        │   └── TrayIconManager.cs        # 托盘图标、右键菜单与悬停预览
        ├── Views/
        │   ├── PopoverWindow.xaml(.cs)   # 托盘额度卡片浮窗
        │   └── SettingsWindow.xaml(.cs)  # 偏好设置窗口（各厂商分页）
        ├── Models/
        │   ├── TokenQuota.cs     # 额度与模型状态定义、国内厂商预设
        │   └── AppSettings.cs    # 本地配置数据结构
        ├── Services/             # 各厂商网络调用实现（平铺，无子目录）
        │   ├── RefreshManager.cs # 定时刷新与多厂商状态调度器
        │   ├── OpenAIService.cs / ClaudeService.cs / GeminiService.cs
        │   ├── DeepSeekService.cs / VolcengineService.cs / KimiService.cs
        │   ├── GLMService.cs / AliyunBailianService.cs
        │   └── CustomProviderService.cs  # OpenAI/Anthropic 协议自定义端点
        ├── Helpers/
        │   └── ProviderIcons.cs  # 厂商标识图标资源
        └── I18n/
            └── LocalizationManager.cs # 中英文切换管理模块
```

更多产品与架构信息参见根目录 `doc/` 下的 [PRD](../doc/PRD_需求文档.md)、
[架构设计](../doc/ARCH_系统架构设计文档.md) 与 [用户手册](../doc/USER_GUIDE_使用说明书.md)。
