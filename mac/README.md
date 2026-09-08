# TokenBar for macOS

**TokenBar - 模型额度监控 / Model Quota Monitor** (macOS Client)

macOS 客户端使用纯 **Swift 5.9+ / SwiftUI** 构建（SPM 管理，无第三方依赖），常驻菜单栏，深度适配深浅色外观。

---

## 🛠️ 环境要求 (Prerequisites)

- **操作系统**: macOS 13.0 (Ventura) 及以上
- **工具链**: Xcode 15+ 或 [Swift 5.9+](https://swift.org) 命令行工具链（`xcode-select --install`）

---

## 🚀 快速构建与运行 (Build & Run)

### 1. 调试运行

```bash
cd mac

# 运行自动化单元测试
swift test

# 直接编译并运行（调试）
swift run
```

### 2. 打包为独立应用 (TokenBar.app)

```bash
# 一键 Release 编译 + 组装 .app 包（universal：同时支持 Apple Silicon 与 Intel）
./Scripts/build_app.sh

# 运行
open build/TokenBar.app
```

`build_app.sh` 会执行 `swift build -c release --arch arm64 --arch x86_64` 交叉编译出
双架构可执行文件，并与 `Resources/Info.plist` 组装为标准的 `build/TokenBar.app`
包结构（Contents/MacOS + Contents/Resources + PkgInfo）。

---

## 🔐 首次启动与 Gatekeeper

本仓库的构建产物**未做开发者签名与公证**，首次双击运行可能被 macOS 拦截，
任选其一放行：

- 系统设置 -> 隐私与安全性 -> 点击「仍要打开」；
- 或对 .app 执行 `xattr -dr com.apple.quarantine build/TokenBar.app`。

如需分发给其他用户，建议自行配置签名（`codesign`）与公证（`notarytool`）。

---

## 📂 项目结构说明

```
mac/
├── Package.swift                 # SPM 构建定义
├── README.md                     # 本说明文档
├── Scripts/
│   └── build_app.sh              # Release 一键打包脚本
├── Resources/
│   └── Info.plist                # 应用包配置 (LSUIElement 等)
├── Sources/TokenBar/
│   ├── main.swift / AppDelegate.swift  # 应用入口与生命周期
│   ├── MenuBar/
│   │   └── MenuBarController.swift     # 菜单栏图标、悬停预览与点击固定
│   ├── Views/
│   │   ├── TokenSummaryPopoverView.swift  # 额度卡片浮窗
│   │   ├── ProviderCardView.swift        # 厂商卡片行
│   │   ├── CustomProviderCardView.swift  # 自定义厂商卡片
│   │   └── SettingsView.swift            # 偏好设置窗口
│   ├── Services/                 # 各厂商网络调用实现（平铺）
│   │   ├── RefreshManager.swift  # 定时刷新与多厂商状态调度器
│   │   ├── OpenAIService.swift / ClaudeService.swift / GeminiService.swift
│   │   ├── DeepSeekService.swift / VolcengineService.swift / KimiService.swift
│   │   ├── GLMService.swift / AliyunBailianService.swift
│   │   ├── CustomProviderService.swift   # OpenAI/Anthropic 协议自定义端点
│   │   └── WebLoginWindowController.swift # Google 网页授权窗口
│   ├── Models/
│   │   └── TokenQuota.swift      # 额度与模型状态定义、国内厂商预设
│   └── I18n/
│       └── I18n.swift            # 中英文切换管理模块
└── Tests/
    └── TokenBarTests/            # 自动化单元测试
```

更多产品与架构信息参见根目录 `doc/` 下的 [PRD](../doc/PRD_需求文档.md)、
[架构设计](../doc/ARCH_系统架构设计文档.md) 与 [用户手册](../doc/USER_GUIDE_使用说明书.md)。
