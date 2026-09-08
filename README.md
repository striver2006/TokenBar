<div align="center">

# ⚡ TokenBar

### 模型额度监控 • Model Quota Monitor

**专为开发者打造的跨平台（macOS / Windows）轻量级 AI 模型额度与用量监控状态栏工具**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/Platform-macOS%2013%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Windows](https://img.shields.io/badge/Platform-Windows%2010%20%2F%2011-blue?logo=windows)](https://www.microsoft.com/windows)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)
[![.NET](https://img.shields.io/badge/.NET-8.0-purple?logo=dotnet)](https://dotnet.microsoft.com/)
[![i18n](https://img.shields.io/badge/i18n-中文%20%7C%20English-green.svg)](#-国际化--i18n)

[简体中文](README.md) | [English](README_EN.md)

</div>

---

## 📖 简介 (Introduction)

随着 Claude Code、Cursor、Continue 等 AI 辅助编程工具的普及，开发者在日常使用中往往面临各种大模型用量黑盒与速率阶梯限制（TPM/RPM、5 小时滚动窗口、每周限额）。

**TokenBar** 是一款常驻于系统状态栏（macOS 菜单栏 / Windows 系统托盘）的开源工具，支持在无需打开繁琐网页后台的情况下，一瞥即知各平台模型的额度水位、剩余百分比及精确重置倒计时。

<div align="center">
<pre>
┌──────────────────────────────────────────────────────────────┐
│  ⚡ TokenBar               模型额度监控              🔄 刷新 │
├──────────────────────────────────────────────────────────────┤
│  🧠 Anthropic (Claude)                   ● (已连接)          │
│     [5小时] 5小时额度        剩余 84%                        │
│     [████████████████████████████░░░░░░]                     │
│     🕒 14:10 ~ 19:10                         剩余 2小时 5分  │
│     ──────────────────────────────────────────               │
│     [每周]  每周额度         剩余 92%                        │
│     [████████████████████████████████░░]                     │
│     🕒 09-04 09:00 ~ 09-11 09:00             剩余 3天 15小时 │
├──────────────────────────────────────────────────────────────┤
│  🌐 OpenAI API                           ● (已连接)          │
│     TPM: 100% 充足 | RPM: 100% 充足                          │
├──────────────────────────────────────────────────────────────┤
│  🕒 更新于: 17:05:00                       ⚙️ 设置    ⚡ 退出 │
└──────────────────────────────────────────────────────────────┘
</pre>
</div>

---

## ✨ 核心特性 (Key Features)

- 🖥️ **跨平台原生体验**：
  - **macOS**：纯 Swift 5.9+ / SwiftUI 构建，深度适配深浅色外观。
  - **Windows**：现代 .NET 8 / C# WPF 架构，完美融入 Windows 10/11 任务栏托盘。
- 👁️ **悬停即览与点击固定**：
  - 鼠标悬停在状态栏图标上短暂停留（macOS 0.15 秒 / Windows 0.2 秒）即可自动弹出用量面板，无需额外点击。
  - 单击图标可锁定面板，方便长时间对照或查阅。
- 🌐 **广泛的模型厂商生态**：
  - **海外主流**：OpenAI (TPM/RPM)、Anthropic (Claude Code 5h/每周双窗口)、Google Gemini / Google One (AI Studio / OAuth 网页授权 / Antigravity 凭据管理器)。
  - **国内前沿**：DeepSeek (余额/速率)、火山方舟 (Ark 接入点)、月之暗面 KIMI、智谱清言 GLM、阿里云百炼 (Token Plan)。
  - **开放生态**：支持通过 OpenAI Chat、OpenAI Response 或 Anthropic 协议自定义任意端点（如 OneAPI、NewAPI、硅基流动、MiniMax、阶跃星辰等）。
- 🌍 **动态中英文双语**：
  - 界面全面支持「简体中文」与「English」实时切换，无需重启即时响应。
- 🔒 **本地安全与零追踪**：
  - 所有 API Key 与凭据仅保存在本机操作系统，不经由任何第三方中间服务器转发，完全开源可审计。

---

## 🗂️ 目录结构 (Directory Layout)

为了兼顾不同操作系统特性，代码仓库划分为以下清晰目录：

```
TokenBar/
├── .gitignore                      # 根目录全局 Git 忽略规则
├── LICENSE                         # MIT 开源协议
├── README.md                       # 中文主说明文档
├── README_EN.md                    # 英文主说明文档
├── doc/                            # 详细产品与技术设计规范
│   ├── PRD_需求文档.md              # 产品需求文档
│   ├── ARCH_系统架构设计文档.md       # 系统架构与协议设计
│   └── USER_GUIDE_使用说明书.md      # 用户安装与配置使用手册
├── mac/                            # macOS 原生客户端代码
│   ├── Package.swift               # SPM 构建定义
│   ├── Sources/TokenBar/           # Swift 源码 (含 I18n、Models、Services、Views)
│   ├── Resources/Info.plist        # 应用包配置
│   ├── Scripts/build_app.sh        # 一键构建打包脚本
│   ├── Tests/                      # 自动化单元测试集
│   └── README.md                   # macOS 构建指引
└── windows/                        # Windows 原生客户端代码
    ├── TokenBar.sln                # Visual Studio 解决方案
    ├── install.ps1                 # 一键安装/升级脚本
    ├── README.md                   # Windows 构建指引
    ├── tools/gui/                  # 托盘实机测试辅助脚本 (PowerShell)
    └── src/TokenBar/               # .NET 8 / WPF 源码与托盘服务
```

---

## 🚀 快速开始 (Quick Start)

### macOS 构建与运行

确保已安装 Xcode 15+ 或 Swift 5.9+ 工具链：

```bash
cd mac

# 1. 运行自动化测试
swift test

# 2. 编译并打包为独立的 TokenBar.app
./Scripts/build_app.sh

# 3. 运行应用
open build/TokenBar.app
```

### Windows 构建与运行

确保已安装 [.NET 8.0 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)：

```bash
cd windows

# 1. 启动调试
dotnet run --project src/TokenBar/TokenBar.csproj

# 2. 发布为独立免安装单文件 (.exe)
dotnet publish src/TokenBar/TokenBar.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o ./publish

# 3. （可选）一键安装/升级到本机：停旧进程 + 复制 exe + 建快捷方式
powershell -ExecutionPolicy Bypass -File install.ps1
```

详细说明见 [windows/README.md](windows/README.md)。

---

## 📚 详细文档库 (Documentation)

- 📑 [产品需求文档 (PRD)](doc/PRD_需求文档.md)：产品全景目标、用户痛点、功能规划。
- 🏗️ [系统架构设计文档 (ARCH)](doc/ARCH_系统架构设计文档.md)：多平台架构、响应头解析机制、数据流与并发模型。
- 📘 [用户使用说明书 (USER GUIDE)](doc/USER_GUIDE_使用说明书.md)：安装教程、各大模型 API Key 获取攻略、常见问题排查。

---

## 🤝 参与贡献 (Contributing)

我们非常欢迎社区开发者提交 Issue、提出新模型厂商支持需求或发起 Pull Request！

1. Fork 本仓库并创建特性分支 (`git checkout -b feature/AmazingFeature`)。
2. 提交您的修改 (`git commit -m 'feat: Add some AmazingFeature'`)。
3. 推送至远程分支 (`git push origin feature/AmazingFeature`)。
4. 在 GitHub 或 GitCode 上开启 Pull Request。

---

## 📄 开源许可证 (License)

本项目基于 [MIT License](LICENSE) 开源协议分发与使用。
