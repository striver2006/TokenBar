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
    - **余额行（纯扣费厂商专属）**：DeepSeek、KIMI、OpenRouter 及识别到余额接口的自定义厂商（如硅基流动、Moonshot 中转）以**金额**展示（如 `¥27.05` / `$12.00`），不再显示进度条与重置倒计时；金额下方左侧为「较上次刷新」的变化量，右侧为「预计可用 ~X 天」（基于近 7 天本地消耗记录估算，样本不足时显示「消耗统计中…」）。
  - **底部栏**：展示最后更新时间戳，右侧提供偏好设置齿轮入口与退出按钮。

### 2.2 右键菜单 (Context Menu)
右键点击状态栏或托盘图标，可呼出快捷上下文菜单：
- **TokenBar - 模型额度监控**（标题展示）
- **立即刷新全部额度**（快捷键 `Cmd+R` / `Ctrl+R`）
- **偏好设置...**（快捷键 `Cmd+,`）
- **退出 TokenBar**（快捷键 `Cmd+Q`）

### 2.3 浮动框卡片显示顺序调整
浮动框中各厂商余额卡片的先后顺序支持自定义：
- **设置入口**：偏好设置 →「显示顺序」页（位于「国内厂商 / 自定义」与「通用设置」之间，macOS 端在下拉选择器中选择「显示顺序」）。
- **调整方式**：页面按当前顺序列出所有已启用的厂商，点击每行的「↑ 上移」「↓ 下移」调整位置；点击「恢复默认顺序」回到出厂排序（OpenAI → Claude → Gemini → DeepSeek → 火山方舟 → KIMI → OpenRouter → GLM → 阿里云百炼 → 自定义厂商）。
- **生效与保存**：修改立即生效并自动保存，浮动框即时按新顺序重渲染；顺序跨重启保留。仅列出已启用厂商，新启用的厂商默认追加在末尾（可再手动调整）。

### 2.4 菜单栏 / 托盘图标旁显示额度（macOS）
可以把某一个厂商的剩余额度直接顶在菜单栏图标旁边，无需展开浮动框：
- **设置入口**：偏好设置 →「通用设置」→「菜单栏显示额度」。
- **配置项**：
  - **开关**：关闭时菜单栏只显示图标（默认关闭）；首次开启会自动选中第一个已启用的厂商。
  - **显示厂商**：从已启用的厂商（含自定义厂商）中选择一个。
  - **显示指标**：
    - `自动（余额优先，额度并列）`：有账户余额的厂商显示余额；否则把 5 小时与周期剩余并列显示（只有一个窗口时只显示该窗口）；
    - `5 小时剩余额度` / `周期剩余额度`：只显示对应的剩余百分比；
    - `账户余额`：只显示余额金额。
- **展示效果**：菜单栏只显示数值、不带厂商名，例如 `34%/67%`（依次为 5 小时剩余、周期剩余）、`45.09`（余额，不带币种符号）；数据未就绪或未授权时显示 `--`。厂商名、额度名称、重置倒计时等完整信息在鼠标悬停图标时的提示中展示。
- **生效与保存**：跟随刷新周期自动更新，修改配置立即生效并跨重启保留；所选厂商被关闭监控或删除后，菜单栏自动回到「仅图标」状态。

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
- **DeepSeek (深度求索)**：在 [platform.deepseek.com](https://platform.deepseek.com) 获取 API Key，填入后将自动同步账户可用余额。可在设置中配置「**余额提醒阈值**」：余额低于该值时托盘弹气泡提醒，看板金额变为橙/红色。
- **火山方舟 (字节跳动)**：前往火山引擎大模型控制台获取 API Key，支持自定义 Endpoint。
- **月之暗面 KIMI**：在 [platform.moonshot.cn](https://platform.moonshot.cn) 获取 Key，支持监测 RPM/TPM 限额与账户余额（同样支持余额提醒阈值）。
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
  - **一键操作**：在 TokenBar 百炼设置页点击「在终端登录百炼 CLI (推荐)」，应用会自动打开「终端」并执行 `bl auth login --console`；若本机未安装 `bl`，终端会直接给出安装命令提示。登录完成后回到设置页点击「保存并刷新检测额度」即可。
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
- 端点为 DeepSeek / Moonshot / 硅基流动时会自动识别并查询账户余额，可在表单中选填「余额提醒阈值」。

#### 小米 MiMo 双模式监控（订阅 Token Plan + 按量余额自动识别）
小米 MiMo 同时提供按量付费与 Token Plan 订阅套餐，TokenBar 通过**双通道自动识别**同时监控：

1. 用预设快捷添加「小米 MiMo (Xiaomi)」，填入 API Key（按量计费监控，展示速率限制）。
2. 若你订阅了 Token Plan 或想看余额：浏览器登录 [platform.xiaomimimo.com](https://platform.xiaomimimo.com)，按 `F12` -> **网络 (Network)** 刷新页面，任选一个 `/api/` 请求，复制其请求头中的完整 `Cookie` 值，粘贴到表单的「**控制台 Cookie**」字段。
3. 保存后卡片将自动展示（有什么显示什么）：
   - **Token Plan 额度**：套餐用量百分比（订阅通道）；
   - **账户余额**：按量余额金额，支持余额提醒阈值与"预计可用 X 天"（按量通道）。

> 说明：MiMo 的余额与套餐查询接口**只接受官网登录态 Cookie**，不接受 API Key（官方限制）。Cookie 失效后对应行会自动消失，重新复制即可；两通道互不影响，只填 API Key 时行为与旧版完全一致。

### 3.7 OpenRouter 配置（聚合平台，美元按量计费）
OpenRouter 为纯按量扣费平台，TokenBar 以**美元余额**方式展示：

1. 登录 [openrouter.ai/keys](https://openrouter.ai/keys) 创建 API Key（`sk-or-...`）。
2. 在 TokenBar 的 OpenRouter 设置页粘贴 Key，点击「保存并测试连接」。
3. **Key 类型说明**：
   - **普通 Key**：只能查询该 Key 自身的用量与限额。若 Key 设置了消费上限，看板会展示「Key 可用额度」金额与「Key 额度」使用百分比。
   - **Management Key**（后台管理密钥）：可查询**账户总余额**（`总充值 - 总消耗`），看板将以「账户可用余额」展示。推荐使用 Management Key 获得完整余额监控。
4. 余额提醒阈值默认为 5（美元），可自行修改。

### 3.8 纯扣费厂商的余额监控说明（消耗统计与提醒）

DeepSeek、KIMI、OpenRouter 等按量计费厂商没有"5 小时/每周"的时间窗口概念，TokenBar 使用不同的展示与提醒逻辑：

- **金额展示**：看板直接显示余额金额，低于阈值变橙、低于阈值一半变红。
- **低余额提醒**：余额首次跌破阈值时弹托盘气泡（macOS 为系统通知），恢复到阈值的 1.2 倍以上后重新武装，避免反复打扰。
- **消耗统计**：每次刷新在本地记录余额（Windows：`%LOCALAPPDATA%\TokenBar\balance_history.json`；macOS：`~/Library/Application Support/TokenBar/balance_history.json`），累积满 1 天以上样本后自动估算日均消耗，显示「预计可用 ~X 天」。全程纯本地计算，不联网上传。
- **较上次变化**：金额下方展示与上一次刷新相比的余额增减（如 `-¥0.85`）。

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
