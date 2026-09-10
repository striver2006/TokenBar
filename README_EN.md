<div align="center">

# ⚡ TokenBar

### Model Quota Monitor

**A lightweight, cross-platform (macOS / Windows) status bar tool designed for developers to monitor AI model quotas, rate limits, and usage.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/Platform-macOS%2013%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Windows](https://img.shields.io/badge/Platform-Windows%2010%20%2F%2011-blue?logo=windows)](https://www.microsoft.com/windows)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)
[![.NET](https://img.shields.io/badge/.NET-8.0-purple?logo=dotnet)](https://dotnet.microsoft.com/)
[![i18n](https://img.shields.io/badge/i18n-English%20%7C%20%E4%B8%AD%E6%96%87-green.svg)](#-internationalization)

[English](README_EN.md) | [简体中文](README.md)

</div>

---

## 📖 Overview

As AI-assisted programming tools like Claude Code, Cursor, and Continue gain widespread adoption, developers frequently face quota limits, rolling consumption windows (such as Claude's 5-hour window), and unexpected rate-limiting errors (HTTP 429).

**TokenBar** resides in your system status bar (macOS Menu Bar / Windows System Tray). It offers instant visibility into your remaining quotas, percentages, and precise reset countdowns across multiple AI platforms without requiring you to repeatedly visit web dashboards.

---

## ✨ Features

- 🖥️ **Native Cross-Platform Support**:
  - **macOS**: Built with Swift 5.9+ and SwiftUI, seamlessly supporting Light and Dark modes.
  - **Windows**: Built with .NET 8 / C# WPF, integrating cleanly with the taskbar tray notification area.
- 👁️ **Hover Preview & Click to Pin**:
  - Automatically pops up the quota card panel after hovering over the tray icon (0.15s on macOS / 0.2s on Windows).
  - Click the icon to pin the panel open for continuous reference during coding sessions.
- 📌 **Always-on Menu Bar Quota (macOS)**:
  - Pick any enabled provider in General settings and its remaining quota is shown right next to the menu bar icon as bare values — e.g. `34%/67%` (5-hour / weekly left) or `45.09` (account balance). Provider name and reset countdown live in the hover tooltip.
- 🌐 **Extensive AI Provider Ecosystem**:
  - **Global**: OpenAI (TPM/RPM rate limits), Anthropic (Claude Code 5-hour rolling window & weekly quota), Google Gemini / Google One (AI Studio / OAuth / Antigravity Credential Manager).
  - **Domestic**: DeepSeek, Volcengine Ark, Moonshot KIMI, Zhipu GLM, Aliyun Bailian (Token Plan quota + account balance, with AccessKey support so several machines can monitor at once).
  - **Custom Endpoints**: Supports custom OpenAI Chat, OpenAI Response, and Anthropic protocols (OneAPI, NewAPI, SiliconFlow, MiniMax, StepFun, etc.).
- 🌍 **Dynamic Bilingual Interface (i18n)**:
  - Instant toggle between **English** and **简体中文** without application restarts.
- 🔒 **Local Security & Zero Tracking**:
  - All API keys, login tokens and cookies live only in the macOS Keychain / Windows Credential Manager, never in the config file. No third-party proxy or telemetry tracking.

---

## 🗂️ Directory Layout

```
TokenBar/
├── .gitignore                      # Root Git ignore rules
├── LICENSE                         # MIT License
├── README.md                       # Chinese README
├── README_EN.md                    # English README
├── doc/                            # Specifications & Documentation
│   ├── PRD_需求文档.md              # Product Requirements Document
│   ├── ARCH_系统架构设计文档.md       # Architecture & Protocols Document
│   └── USER_GUIDE_使用说明书.md      # User Installation & Configuration Guide
├── mac/                            # macOS Native Client
│   ├── Package.swift               # SPM definition
│   ├── Sources/TokenBar/           # Swift source code
│   ├── Resources/Info.plist        # Bundle plist configuration
│   ├── Scripts/build_app.sh        # Release packaging script
│   ├── Tests/                      # Automated unit test suite
│   └── README.md                   # macOS build instructions
└── windows/                        # Windows Native Client
    ├── TokenBar.sln                # Visual Studio solution
    ├── install.ps1                 # One-click install/upgrade script
    ├── README.md                   # Windows build instructions
    ├── tools/gui/                  # Live GUI test helpers (PowerShell)
    └── src/TokenBar/               # .NET 8 / WPF source code & tray services
```

---

## ⬇️ Download & Install

Prebuilt binaries are available for released versions — no build required:

- **GitHub Releases**: https://github.com/striver2006/TokenBar/releases
- **GitCode Releases**: https://gitcode.com/czb99/TokenBar/releases

| Platform | Artifact | Notes |
| --- | --- | --- |
| Windows 10/11 (Intel/AMD) | `TokenBar-v*-win-x64.exe` | Self-contained single file, no .NET install needed — just run it. For shortcuts & uninstall entries, copy the downloaded exe to `windows/publish/TokenBar.exe` and run `windows/install.ps1` |
| Windows 10/11 (ARM devices) | `TokenBar-v*-win-arm64.exe` | Same as above. ARM64 Windows can also run the x64 build via emulation, but the native build uses less memory |
| macOS 13+ (Universal: Intel & Apple Silicon) | `TokenBar-v*-macOS-universal.zip` | Unzip and drag `TokenBar.app` into /Applications. The build is unsigned/notarized — on first launch allow it via System Settings → Privacy & Security → "Open Anyway" |

Verify downloads with the `SHA256SUMS.txt` attached to each release.

---

## 🚀 Quick Start

### macOS

Requires Xcode 15+ or Swift 5.9+:

```bash
cd mac

# 1. Run unit tests
swift test

# 2. Build release bundle TokenBar.app
./Scripts/build_app.sh

# 3. Launch application
open build/TokenBar.app
```

### Windows

Requires [.NET 8.0 SDK](https://dotnet.microsoft.com/download/dotnet/8.0):

```bash
cd windows

# 1. Run & debug
dotnet run --project src/TokenBar/TokenBar.csproj

# 2. Publish self-contained single-file executable
dotnet publish src/TokenBar/TokenBar.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o ./publish

# 3. (Optional) One-click local install/upgrade: stop old process, copy exe, create shortcuts
powershell -ExecutionPolicy Bypass -File install.ps1
```

See [windows/README.md](windows/README.md) for details.

---

## 📚 Documentation

- 📑 [PRD (Requirements Document)](doc/PRD_需求文档.md)
- 🏗️ [Architecture Document](doc/ARCH_系统架构设计文档.md)
- 📘 [User Guide](doc/USER_GUIDE_使用说明书.md)

---

## 🤝 Contributing

Contributions, issues, and feature requests are welcome! Feel free to check the issues page or submit a PR.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
