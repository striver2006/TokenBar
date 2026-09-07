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
如需打包为无需用户安装 .NET 环境的单文件可执行文件 (`.exe`)：

```bash
dotnet publish src/TokenBar/TokenBar.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o ./publish
```
发布后的 `TokenBar.exe` 将输出到 `./publish` 目录中，体积轻巧且即开即用。

---

## 📂 项目结构说明

```
windows/
├── TokenBar.sln                  # Visual Studio 解决方案
├── README.md                     # 本说明文档
└── src/
    └── TokenBar/
        ├── TokenBar.csproj       # WPF 托盘应用项目文件
        ├── App.xaml / .cs        # 应用入口与生命周期管理
        ├── Tray/
        │   └── TrayIconManager.cs# 任务栏系统托盘图标与右键菜单
        ├── Views/
        │   ├── PopoverWindow.xaml# 托盘卡片浮窗界面
        │   └── SettingsWindow.xaml # 偏好设置窗口
        ├── Models/
        │   ├── TokenQuota.cs     # 额度与模型状态定义
        │   └── AppSettings.cs    # 本地配置数据结构
        ├── Services/
        │   ├── RefreshManager.cs # 定时刷新与多厂商状态调度器
        │   └── Providers/        # 各模型厂商网络调用实现
        └── I18n/
            └── LocalizationManager.cs # 中英文切换管理模块
```
