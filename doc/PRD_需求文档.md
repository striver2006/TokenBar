# TokenBar 产品需求文档 (PRD)

> **产品名称**：TokenBar  
> **副标题**：模型额度监控 / Model Quota Monitor  
> **定位**：专为开发者量身打造的跨平台（macOS / Windows）轻量级 AI 大模型额度与用量监控状态栏工具。

---

## 1. 产品背景与目标

随着生成式 AI 和大语言模型（LLM）在日常研发、写作和编程辅助中的深度普及，开发者往往同时使用多家主流模型提供商（如 OpenAI、Anthropic Claude、Google Gemini、DeepSeek、火山方舟、月之暗面 KIMI、智谱 GLM、阿里云百炼）以及各类第三方中转 API。

### 1.1 痛点分析
1. **额度焦虑与黑盒限制**：
   - Claude Code 实施了 5 小时滚动窗口与每周限额，用尽前无法预知何时重置。
   - OpenAI 与各类国产厂商存在严格的 TPM (Tokens Per Minute) 与 RPM (Requests Per Minute) 速率阶梯。
   - 开发者在使用 IDE 插件（如 Cursor、Continue、Cline）或命令行 CLI 时，经常在关键时刻突然被 429 Rate Limit 拦截，严重打断心流。
2. **多平台查询繁琐**：
   - 用户不得不频繁打开 5~10 个不同的网页后台（OpenAI Platform、Anthropic Console、Google AI Studio、DeepSeek 开放平台、火山引擎控制台等）去核对余额或调用量。
3. **缺少常驻且轻量的桌面端体验**：
   - 市面多数工具需要打开笨重的 Electron 窗口，没有轻快原生、嵌入系统状态栏或托盘的极简应用。

### 1.2 产品目标
- **零打扰常驻**：常驻在 macOS 菜单栏或 Windows 任务栏系统托盘，图标直观指示当前系统健康度。
- **一瞥即知**：鼠标滑过即可弹出浮窗，快速预览各厂商 5 小时/每周额度进度条、剩余百分比与精确重置倒计时。
- **广泛兼容**：原生支持 8 大主流模型平台以及 OpenAI Chat / Response / Anthropic 兼容中转协议。
- **隐私至上**：所有配置保存在本地，绝无第三方云端中转或日志回传。
- **国际化**：原生支持中英文无缝切换。

---

## 2. 用户画像与核心使用场景

| 用户类型 | 典型场景 | 核心价值 |
| :--- | :--- | :--- |
| **AI 编程工程师** | 使用 Claude Code / Cursor / Cline 重度编码 | 随时关注 5 小时额度水位，避免写到一半遭遇 429 报错 |
| **独立开发者 / 创作者** | 调用多厂商 API 开发智能体或内容生成 | 集中式查看 OpenAI、DeepSeek、百炼 Token Plan 等账单与速率限制 |
| **多设备多环境用户** | 在 macOS 与 Windows 工作站之间切换办公 | 两端拥有高度一致的操作逻辑与配置格式 |

---

## 3. 功能需求规格 (Functional Requirements)

### 3.1 跨平台系统驻留与交互
1. **状态栏 / 系统托盘常驻**：
   - **macOS**：原生 `NSStatusItem`，自适应深色/浅色模式，支持墨水图标。
   - **Windows**：系统托盘 `NotifyIcon`，集成到右下角通知区域。
2. **鼠标悬停预览 (Hover Preview)**：
   - 鼠标悬停在图标上方 0.15 秒后自动展开 Popover 卡片浮窗。
   - 移出后延迟 0.35 秒平滑关闭；若用户在浮窗内操作则保持展示。
   - 悬停预览可在「通用设置」中自由开启或关闭。
3. **点击交互与固定 (Click to Pin)**：
   - 左键单击：立即展示/隐藏浮窗，点击打开后处于“固定”状态，避免误触关闭。
   - 右键单击：弹出原生上下文菜单，包含「立即刷新全部额度」、「偏好设置...」与「退出 TokenBar」。

### 3.2 支持的模型厂商与配额机制

| 厂商 | 监控指标 / 配额类型 | 接入方式 |
| :--- | :--- | :--- |
| **OpenAI** | TPM / RPM 速率限制、可用模型清单、组织 ID | 官方 API Key / 反向代理中转 |
| **Anthropic (Claude)** | Claude Code 5 小时滚动额度、每周额度、重置时间倒计时 | 本地 `~/.claude.json` / 网页 OAuth 授权 / 官方 API Key |
| **Google Gemini** | 免费/付费层速率、API 配额状态 | Google AI Studio API Key / 本地 `~/.gemini/` / OAuth 凭证 |
| **DeepSeek (深度求索)** | 账户余额、TPM/RPM 速率、可用模型 | DeepSeek 开放平台 API Key |
| **火山方舟 (字节跳动)** | 接入点推理配额、API 连通性 | 火山方舟 API Key |
| **KIMI (月之暗面)** | 用户余额、8k/32k/128k 速率限额 | Moonshot API Key |
| **GLM (智谱清言)** | 账户调用状态、BigModel 接口健康度 | 智谱 API Key |
| **阿里云百炼** | 百炼 Token Plan 包月额度、DashScope 兼容接口 | 百炼 API Key / 专属 Token Plan 端点 |
| **国内厂商 / 自定义** | 支持 OpenAI Chat、OpenAI Response 与 Anthropic 协议 | 自建 OneAPI / NewAPI / 硅基流动 / MiniMax / 阶跃星辰 / 零一万物 / 百度千帆等 |

### 3.3 界面与多语言支持 (i18n)
1. **应用命名与副标题**：
   - 应用名：`TokenBar`（中英文保持一致）
   - 副标题（中文）：`模型额度监控`
   - 副标题（英文）：`Model Quota Monitor`
2. **语言切换**：
   - 支持 3 种语言模式：
     - `跟随系统 (System Default)`
     - `简体中文 (Simplified Chinese)`
     - `English`
   - 用户在通用设置中切换后，**界面所有视图、托盘菜单、卡片文本即时动态刷新，无需重启程序**。

### 3.4 定时主动刷新与状态管理
- 支持后台定期静默轮询刷新：可选 1 分钟、5 分钟（推荐）、15 分钟、30 分钟、60 分钟。
- 具备全局并发限制与防抖保护，避免突发高频请求消耗用户 API 次数。
- 卡片右侧具备实时状态指示灯（绿色表示连接正常、橙色表示待授权或异常、转圈表示正在同步）。

---

## 4. 非功能需求规格 (Non-Functional Requirements)

1. **性能与轻量化**：
   - macOS 客户端空闲内存占用保持在 30MB 左右，CPU 占用接近 0%。
   - Windows 客户端基于 .NET 8 原生 WPF，冷启动时间 < 0.8s。
2. **安全性与隐私保护**：
   - 所有密钥、Cookie、Token 均保存在本地操作系统受保护的持久化介质中。
   - 绝不通过任何第三方后端转发或采集用户凭证，符合开源安全审计标准。
3. **开源友好与工程规范**：
   - 采用清晰的架构分层，代码划分为 `mac/` 与 `windows/` 独立工程。
   - 完备的单元测试覆盖与持续集成支持。
