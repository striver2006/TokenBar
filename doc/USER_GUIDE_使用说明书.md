# TokenBar 用户使用说明书 (User Guide)

欢迎使用 **TokenBar - 模型额度监控 / Model Quota Monitor**！  
本文档将指导您在 macOS 或 Windows 操作系统上快速安装、配置各大 AI 模型厂商凭证并进行日常监控。

---

## 1. 软件安装与启动

### 1.1 macOS 系统
1. **系统要求**：macOS 13.0 (Ventura) 及更高版本。
2. **下载与安装**：
   - 从 GitHub Releases 或源码中获取编译产物 `TokenBar.app`。
   - 将 `TokenBar.app` 拖拽至系统的「应用程序 (Applications)」文件夹。
3. **首次启动**：
   - 双击打开 `TokenBar`。若系统提示“未知开发者”拦截，请在「系统设置」->「隐私与安全性」中点击「仍要打开」。
   - 启动成功后，您将在顶部菜单栏右上角看到一个精巧的仪表盘图标。

### 1.2 Windows 系统
1. **系统要求**：Windows 10 (1809 及以上) 或 Windows 11。
2. **运行时环境**：已安装 [.NET 8.0 Runtime](https://dotnet.microsoft.com/download/dotnet/8.0)（若使用独立打包的 Self-contained 单文件版本则无需手动安装）。
3. **启动应用**：
   - 双击运行 `TokenBar.exe`。
   - 启动后，TokenBar 会自动常驻在右下角任务栏通知区域（系统托盘）中。
4. **从源码构建安装（可选）**：克隆仓库后在 `windows/` 目录执行
   `dotnet publish src/TokenBar/TokenBar.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o publish`，
   再运行 `powershell -ExecutionPolicy Bypass -File install.ps1` 即可一键安装/升级到本机
   （自动停止旧实例、复制 exe 至 `%LOCALAPPDATA%\Programs\TokenBar\` 并创建快捷方式）。
   注意必须使用自包含单文件参数发布，否则安装后应用无法启动。

---

## 2. 界面与交互指引

### 2.1 状态看板 (Popover 浮窗)
- **呼出看板**：
  - **鼠标悬停**：将鼠标移至状态栏图标上方，卡片将自动滑出（macOS 约 0.15 秒 / Windows 约 0.2 秒后触发，可在设置中开启或关闭此功能）。
  - **鼠标左键单击**：点击图标即可固定展开看板，此时移开鼠标不会自动关闭。再次点击可收起。
- **看板元素说明**：
  - **顶部标题**：展示 `TokenBar` 标识与副标题 `模型额度监控 / Model Quota Monitor`。
  - **即时刷新按钮**：点击右上角「刷新」按钮可立刻并行更新所有已启用的厂商数据。
  - **厂商卡片**：
    - 状态指示灯：🟢 绿色代表连接正常且额度同步成功；🟠 橙色代表未授权或需要核对 Key；转圈动画代表正在拉取。
    - 额度进度条：展示 5 小时滚动窗口与每周配额的剩余百分比，配合醒目的红/橙/绿渐变色。
    - 重置倒计时：实时呈现剩余天数、小时数和分钟数。
  - **底部栏**：展示最后更新时间戳，右侧提供偏好设置齿轮入口与退出按钮。

### 2.2 右键菜单 (Context Menu)
右键点击状态栏或托盘图标，可呼出快捷上下文菜单：
- **TokenBar - 模型额度监控**（标题展示）
- **立即刷新全部额度**（快捷键 `Cmd+R` / `Ctrl+R`）
- **偏好设置...**（快捷键 `Cmd+,`）
- **退出 TokenBar**（快捷键 `Cmd+Q`）

---

## 3. 厂商配置教程 (Step-by-Step)

在状态看板底部点击齿轮图标，或通过右键菜单进入「偏好设置」。

### 3.1 OpenAI 配置
1. 登录 [OpenAI Platform](https://platform.openai.com) -> 进入 **API Keys**。
2. 创建新的 Secret Key（格式如 `sk-...` 或 `sk-proj-...`）。
3. 在 TokenBar 的 OpenAI 设置页粘贴 Key。
4. （可选）若您使用的是第三方中转反代，可将默认接入端点 `https://api.openai.com/v1` 修改为您的代理地址。
5. 点击「保存并测试连接」，系统将检测网络与可用模型。

### 3.2 Anthropic (Claude) 配置
TokenBar 独家支持双重模式：
- **方式一：Anthropic API Key**：
  - 在 [Anthropic Console](https://console.anthropic.com) 生成 `sk-ant-...` 密钥，粘贴后点击保存。
- **方式二：Claude Code 订阅授权 (推荐)**：
  - **自动读取本地**：若您在终端中已登录过 Claude Code CLI，点击「读取本地 CLI 授权」按钮，TokenBar 将自动读取 `~/.claude.json` 中的会话凭据。
  - **网页登录授权**：点击「网站登录授权」，在弹出窗口完成登录即可完成绑定。

### 3.3 Google Gemini / Google One 配置
- **方式一：Google AI Studio API Key (永久有效，推荐)**：
  - 前往 [aistudio.google.com/app/apikey](https://aistudio.google.com/app/apikey) 获取免费密钥并填入，支持监控 Gemini 模型的 RPM 速率配额与连接状态。
- **方式二：Google 账号授权 / 本地凭证 (Google One / Antigravity)**：
  - **Google 网站登录授权**：点击设置页面的「Google 网站登录授权」按钮，若本地已登录 Google 账号将一键无缝绑定；若未检测到，将引导通过浏览器完成 OAuth 认证。
  - **自动读取本地 / Antigravity 凭证**：
    - **Windows**：TokenBar 原生集成 Windows 凭据管理器（Credential Manager），可自动识别并提取 Antigravity CLI (`agy`) / Antigravity IDE 登录的 Google One PRO 凭据（`gemini:antigravity`），自动刷新访问令牌并调用 Google Code Assist 配额接口，呈现与 **Antigravity 官方用量面板一致** 的 Gemini Models **5小时滚动算力额度** 与 **每周额度**（真实剩余比例与重置时间）。同时兼容读取 `%USERPROFILE%\.gemini\` 下的本地凭证。
    - **macOS**：支持从 Keychain 以及 `~/.gemini/` 自动读取凭证，额度数据来源与 Windows 端一致。

### 3.4 国内主流厂商配置
- **DeepSeek (深度求索)**：在 [platform.deepseek.com](https://platform.deepseek.com) 获取 API Key，填入后将自动同步账户可用余额。
- **火山方舟 (字节跳动)**：前往火山引擎大模型控制台获取 API Key，支持自定义 Endpoint。
- **月之暗面 KIMI**：在 [platform.moonshot.cn](https://platform.moonshot.cn) 获取 Key，支持监测 RPM/TPM 限额。
- **智谱清言 GLM**：在 [open.bigmodel.cn](https://open.bigmodel.cn) 获取 API Key。

### 3.5 阿里云百炼 (Token Plan) 专属配置与多端同步

TokenBar 支持实时监控阿里云百炼的 **5 小时滚动滑动窗口** 与 **7 天周期额度**。

#### 1. 额度获取机制说明
- 阿里云百炼的官方 API Key（包括兼容 OpenAI 的端点）仅用于模型对话与推理，**服务端未开放通过 API Key 查询 Token Plan 额度的接口**。
- 配额查询必须通过百炼控制台网关接口（即官方 CLI 的 `bl usage token-plan` 命令）或控制台网页会话获取。

#### 2. 授权方式与多设备（macOS / Windows）并发指南

- **方式一：OpenAPI AK/SK 认证（最推荐，支持 Mac 与 Windows 同时在线）**：
  - **原理**：阿里云 AccessKey (AK/SK) 为服务端调用凭证，**不受浏览器单点登录 (SSO) 会话互踢限制**。百炼 CLI 原生支持在控制台 Token 过期时利用 AK/SK 自动调用 `GenerateCLIAccessToken` 无感换取控制台凭证。
  - **操作步骤**：
    1. 前往 [阿里云 RAM 控制台 AccessKey 页面](https://ram.console.aliyun.com/manage/ak) 创建 AccessKey（建议创建专用的 RAM 子用户并授予百炼工作空间权限）。
    2. 分别在 Mac 和 Windows 终端执行一次：
       ```bash
       bl auth login --open-api --access-key-id <你的AccessKey_ID> --access-key-secret <你的AccessKey_Secret>
       ```
    3. 在 TokenBar 设置中开启「阿里云百炼 (Token Plan)」，点击「保存并刷新检测额度」即可。
    4. **两台设备可共用同一对 AK/SK（或各自使用独立的子账号 AK/SK），永久稳定并发监控，互不下线**。

- **方式二：控制台浏览器登录（`bl auth login --console`）**：
  - **适用**：仅单台设备使用的场景。
  - **注意**：同一主账号若在 Mac 和 Windows 上分别通过浏览器登录，后登录的设备会将前一设备的 Web 会话注销（触发单点登录互踢）。
  - **多端共用技巧**：在其中一台设备完成浏览器登录后，直接将生成的配置文件同步至另一台设备，两端共用同一个有效 Token：
    - Windows 路径：`C:\Users\<用户名>\.bailian\config.json`
    - macOS 路径：`~/.bailian/config.json`

- **方式三：控制台网页 Cookie 授权**：
  - 在 TokenBar 偏好设置的百炼选项卡中，点击「网站登录授权」，在弹出的 WebView 中登录阿里云账号，应用将自动捕获登录 Cookie 并直调网关查询。

### 3.6 国内第三方厂商与自定义端点
在「国内厂商 / 自定义」标签页，点击「＋ 添加新厂商」：
- 提供丰富的快捷预填：**硅基流动 (SiliconFlow)、MiniMax、阶跃星辰 (StepFun)、零一万物 (01.AI)、百度千帆、腾讯混元、小米 MiMo** 等。
- 支持指定协议：`OpenAI Chat`、`OpenAI Response` 或 `Anthropic` 兼容格式。

---

## 4. 国际化与语言切换

1. 打开「偏好设置」-> 选择「通用设置」选项卡。
2. 找到「**界面语言**」（英文环境下显示为「**Language**」）下拉菜单：
   - **跟随系统 (System)**：自动跟随 macOS 或 Windows 当前的系统显示语言。
   - **简体中文**：强制使用全中文界面。
   - **English**：强制使用全英文界面。
3. 切换即时生效，所有看板、卡片、下拉框、设置表单和系统托盘菜单将即时同步更新为所选语言。

---

## 5. 常见问题排查 (FAQ)

**Q1：为什么状态栏卡片显示“未授权”或橙色指示灯？**  
A：请进入设置检查该厂商的 API Key 是否正确填写，或检查网络是否需要配置系统代理以连通海外服务（如 OpenAI、Claude）。

**Q2：修改刷新频率后多久生效？**  
A：刷新频率在设置中调整后会立即重置定时器并生效。推荐设定为 5 分钟或 15 分钟。

**Q3：我的 API Key 会被上传到别人的服务器吗？**  
A：**绝对不会**。TokenBar 是纯粹的开源单机客户端，所有网络请求均为本机直接请求对应厂商官方 API，没有中间商，代码完全透明开放。

**Q4：为什么 Mac 和 Windows 两台主机一个登录了百炼，另一个就下线了？**  
A：这是因为阿里云控制台采用网页单点登录（Web SSO）会话保护机制。如果在两台机器上分别执行 `bl auth login --console`，后登录的设备会将上一台设备的 Web 会话注销，导致原设备的 `access_token` 失效。  
**最佳解决方案**：改用 OpenAPI 凭证进行认证，两台机器终端分别执行：  
`bl auth login --open-api --access-key-id <AK_ID> --access-key-secret <AK_SECRET>`  
AK/SK 为服务端凭据，不受网页端单点登录互踢限制，且百炼 CLI 会在后台自动无感续期令牌。或者将一台机器登录生成的 `config.json` 直接拷贝至另一台机器共用同一个会话。

**Q5：我已经在百炼控制台创建并输入了 API Key，为什么百炼还是无法获取额度？**  
A：阿里云百炼的官方 API Key（包括兼容 OpenAI 的端点）仅用于模型对话与推理，服务端并未开放通过 API Key 查询 Token Plan 额度的 API。监控 5 小时与每周额度必须依赖百炼控制台权限，请在终端配置 OpenAPI AK/SK 或使用网页登录授权。
