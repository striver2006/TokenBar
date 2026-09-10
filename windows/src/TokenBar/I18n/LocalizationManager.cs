using System;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using TokenBar.Models;

namespace TokenBar.I18n
{
    public class LocalizationManager : INotifyPropertyChanged
    {
        public static LocalizationManager Instance { get; } = new LocalizationManager();

        private AppLanguage _currentLanguage = AppLanguage.System;

        public event PropertyChangedEventHandler? PropertyChanged;

        public AppLanguage CurrentLanguage
        {
            get => _currentLanguage;
            set
            {
                if (_currentLanguage != value)
                {
                    _currentLanguage = value;
                    OnPropertyChanged(string.Empty); // Notify all properties changed
                }
            }
        }

        private LocalizationManager() { }

        public void SetLanguage(AppLanguage lang)
        {
            CurrentLanguage = lang;
        }

        public bool IsChinese
        {
            get
            {
                if (_currentLanguage == AppLanguage.ZhHans) return true;
                if (_currentLanguage == AppLanguage.En) return false;
                return CultureInfo.CurrentUICulture.TwoLetterISOLanguageName.Equals("zh", StringComparison.OrdinalIgnoreCase);
            }
        }

        protected void OnPropertyChanged([CallerMemberName] string? propertyName = null)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }

        // App & Header
        public string AppName => "TokenBar";
        public string Subtitle => IsChinese ? "模型额度监控" : "Model Quota Monitor";
        public string Refresh => IsChinese ? "刷新" : "Refresh";
        public string Refreshing => IsChinese ? "刷新中..." : "Refreshing...";
        public string Ready => IsChinese ? "准备就绪" : "Ready";
        public string UpdatedAt => IsChinese ? "更新于: " : "Updated: ";
        public string AttemptedAt => IsChinese ? "尝试于: " : "Tried: ";
        public string RefreshFailedRound => IsChinese ? "本轮刷新失败" : "last round failed";
        public string ErrRefreshTimeout => IsChinese ? "刷新超时，已跳过本轮" : "Refresh timed out; round skipped";
        public string DataStale => IsChinese ? "数据可能已过期" : "Data may be stale";
        public string OpenSettings => IsChinese ? "偏好设置..." : "Settings...";
        public string QuitApp => IsChinese ? "退出 TokenBar" : "Quit TokenBar";
        public string RefreshAll => IsChinese ? "立即刷新全部额度" : "Refresh All Quotas Now";

        // Windows & Quotas
        public string FiveHourWindow => IsChinese ? "5小时" : "5-Hour";
        public string WeeklyWindow => IsChinese ? "每周" : "Weekly";
        public string Remaining => IsChinese ? "剩余" : "Left";
        public string UnusedFull => IsChinese ? "未消耗 / 100% 充足" : "Unused / 100% Available";
        public string ResetTimeReached => IsChinese ? "已到重置时间 / 刷新中" : "Reset time reached / Refreshing";
        public string FiveHourIdle => IsChinese ? "5小时窗口已重置 (调用后开启)" : "5h window reset (starts on call)";
        public string Configure => IsChinese ? "去配置" : "Configure";
        public string NotAuthorized => IsChinese ? "尚未完成授权配置" : "Authorization required";
        public string SyncingData => IsChinese ? "正在同步额度信息..." : "Syncing quota data...";
        public string ServiceOperational => IsChinese ? "服务可用，接口正常" : "Operational & healthy";
        public string TimeDaysHours => IsChinese ? "剩余 {0}天 {1}小时" : "{0}d {1}h left";
        public string TimeHoursMinutes => IsChinese ? "剩余 {0}小时 {1}分" : "{0}h {1}m left";
        public string TimeMinutes => IsChinese ? "剩余 {0}分钟" : "{0}m left";

        // Navigation & Titles
        public string CurrentConfigItem => IsChinese ? "当前配置项:" : "Current:";
        public string GeneralSettings => IsChinese ? "通用设置" : "General";
        public string CustomProviders => IsChinese ? "国内厂商 / 自定义" : "Custom Providers";
        public string DisplayOrder => IsChinese ? "显示顺序" : "Display Order";
        public string DisplayOrderSubtitle => IsChinese ? "调整浮动框中各厂商余额卡片的先后顺序" : "Reorder provider balance cards in the popover";
        public string DisplayOrderHint => IsChinese ? "使用上移 / 下移调整顺序，修改立即生效并自动保存；未列出的新启用厂商将排在末尾。" : "Use Move Up / Move Down to reorder. Changes apply to the popover immediately; newly enabled providers are appended at the end.";
        public string MoveUp => IsChinese ? "上移" : "Up";
        public string MoveDown => IsChinese ? "下移" : "Down";
        public string ResetOrder => IsChinese ? "恢复默认顺序" : "Reset to Default";
        public string NoEnabledProviders => IsChinese ? "尚未启用任何厂商，请先在各厂商页开启监控" : "No providers enabled yet. Turn on monitoring in each provider tab first.";
        public string GeneralPreferencesTitle => IsChinese ? "通用偏好设置" : "General Preferences";
        public string GeneralSubtitle => IsChinese ? "应用基础偏好与自启动配置" : "General runtime preferences & interface";
        public string InterfaceLanguage => IsChinese ? "界面语言" : "Language";
        public string LanguageSystem => IsChinese ? "跟随系统" : "System";
        public string RefreshInterval => IsChinese ? "定期主动刷新周期" : "Auto-Refresh Interval";
        public string Refresh1Min => IsChinese ? "1 分钟" : "1 Minute";
        public string Refresh5Min => IsChinese ? "5 分钟 (推荐)" : "5 Minutes (Recommended)";
        public string Refresh15Min => IsChinese ? "15 分钟" : "15 Minutes";
        public string Refresh30Min => IsChinese ? "30 分钟" : "30 Minutes";
        public string Refresh60Min => IsChinese ? "60 分钟" : "60 Minutes";
        public string EnableHoverTitle => IsChinese ? "鼠标悬停自动显示小提示浮窗" : "Hover Preview";
        public string EnableHoverSubtitle => IsChinese ? "鼠标移动到托盘图标上方时自动展示额度卡片" : "Show quota popover when cursor hovers tray icon";
        public string LaunchAtLoginTitle => IsChinese ? "开机自动启动" : "Launch at Login";
        public string LaunchAtLoginSubtitle => IsChinese ? "登录 Windows 时自动在系统托盘运行 TokenBar" : "Automatically launch TokenBar when logging into Windows";
        // 版本号单源：TokenBar.csproj 的 <Version>，经 AssemblyInformationalVersion 读出
        public string AppAboutFooter => IsChinese
            ? $"TokenBar v{TokenBar.Services.AppVersion.Short} • 模型额度监控"
            : $"TokenBar v{TokenBar.Services.AppVersion.Short} • Model Quota Monitor";
        public string SaveAllSettings => IsChinese ? "保存全部设置" : "Save All Settings";
        public string SelectPresetPrompt => IsChinese ? "选择常用厂商配置..." : "Select preset...";
        public string QuotaBadge => IsChinese ? "配额" : "Quota";
        public string RateBadge => IsChinese ? "速率" : "Rate";
        public string BalanceBadge => IsChinese ? "余额" : "Balance";
        public string EnableMonitoring => IsChinese ? "启用监控" : "Enable Monitoring";

        // Balance (pay-as-you-go) providers
        public string BalanceVsLast => IsChinese ? "较上次 {0}" : "Since last {0}";
        public string ForecastDays => IsChinese ? "预计可用 ~{0:0} 天" : "~{0:0} days left";
        public string ForecastCollecting => IsChinese ? "消耗统计中…" : "Collecting usage stats…";
        public string LowBalanceTitle => IsChinese ? "余额不足提醒" : "Low Balance";
        public string LowBalanceBody => IsChinese ? "{0} 余额仅剩 {1}，请及时充值" : "{0} balance is low: {1}. Please top up.";
        public string BalanceThresholdLabel => IsChinese ? "余额提醒阈值 (按账户币种)" : "Low-balance Alert Threshold (account currency)";
        public string BalanceThresholdHint => IsChinese ? "余额低于该值时托盘气泡提醒，并在额度卡片中变为橙/红色。" : "A tray balloon is shown and the balance turns orange/red when below this value.";
        public string ConsoleCookieLabel => IsChinese ? "控制台 Cookie (选填)" : "Console Cookie (optional)";
        public string ConsoleCookieHint => IsChinese ? "小米 MiMo 等厂商的余额与套餐用量查询需要官网登录态：浏览器登录后按 F12 -> 网络(Network) 复制请求 Cookie 粘贴于此。" : "Balance/plan usage queries for vendors like Xiaomi MiMo require the web session cookie: log in, press F12 -> Network, copy the request Cookie and paste it here.";

        // Provider Titles & Subtitles
        public string OpenAITitle => "OpenAI API";
        public string OpenAISubtitle => IsChinese ? "配置官方或代理 API KEY，监控 TPM/RPM 速率限制与可用模型" : "Configure API Key to monitor TPM/RPM limits & models";
        public string AnthropicTitle => "Anthropic (Claude)";
        public string AnthropicSubtitle => IsChinese ? "同时支持 Anthropic API Key (官方/代理) 与 Claude Code 订阅授权 (网页/本地)" : "Supports Anthropic API Key and Claude Code subscriptions";
        public string GeminiTitle => "Google Gemini";
        public string GeminiSubtitle => IsChinese ? "支持 Google AI Studio API Key (永久有效) 或 Google 账号本地凭证" : "Supports Google AI Studio API Key and OAuth credentials";
        public string DeepSeekTitle => IsChinese ? "DeepSeek (深度求索) 授权" : "DeepSeek API";
        public string DeepSeekSubtitle => IsChinese ? "配置 DeepSeek API Key，自动查询账户可用余额与 TPM/RPM 速率限制" : "Configure DeepSeek API Key to monitor balance & rate limits";
        public string VolcengineTitle => IsChinese ? "火山方舟 (字节跳动)" : "Volcengine Ark (ByteDance)";
        public string VolcengineSubtitle => IsChinese ? "配置火山方舟 API Key，监控大模型接入点与调用配额" : "Configure Ark API Key to monitor model endpoint quotas";
        public string KimiTitle => IsChinese ? "KIMI (月之暗面)" : "KIMI (Moonshot AI)";
        public string KimiSubtitle => IsChinese ? "配置 Moonshot API Key，查询账户余额与 RPM/TPM 限额" : "Configure Moonshot API Key to monitor balance & limits";
        public string OpenRouterTitle => "OpenRouter";
        public string OpenRouterSubtitle => IsChinese
            ? "配置 OpenRouter API Key（查询账户余额需 Management Key），纯按量扣费美元余额监控"
            : "Configure an OpenRouter API key (Management key for account balance), pay-as-you-go balance in USD";
        public string HintOpenRouterKey => IsChinese
            ? "可在 openrouter.ai/keys 创建。普通 Key 仅能查询自身用量；查询账户余额请使用后台创建的 Management Key。"
            : "Create at openrouter.ai/keys. Regular keys expose per-key usage only; use a Management Key to query the account balance.";
        public string GLMTitle => IsChinese ? "GLM (智谱清言)" : "GLM (Zhipu AI)";
        public string GLMSubtitle => IsChinese ? "配置智谱 BigModel API Key，实时监测账户与接口状态" : "Configure Zhipu BigModel API Key to monitor quota & status";
        public string AliyunTitle => IsChinese ? "阿里云百炼 (Token Plan)" : "Aliyun Bailian (Token Plan)";
        public string AliyunSubtitle => IsChinese ? "配置阿里云百炼 DashScope API Key、CLI 或 Token Plan 端点" : "Configure DashScope API Key, CLI or Token Plan endpoint";
        public string CustomTitle => IsChinese ? "国内厂商 / 自定义接口" : "Custom & Domestic Providers";
        public string CustomSubtitle => IsChinese ? "支持 OpenAI Chat Completions、OpenAI Response 或 Anthropic 协议" : "Supports OpenAI Chat, Response, and Anthropic protocols";

        // Status & Actions
        public string StatusConnected => IsChinese ? "已连接并可用" : "Connected & Active";
        public string StatusNotConnected => IsChinese ? "未授权连接" : "Not Authorized";
        public string ApiKeyLabel => IsChinese ? "API KEY" : "API Key";
        public string ApiEndpointLabel => IsChinese ? "API 接入端点" : "API Endpoint";
        public string OrgIdLabel => IsChinese ? "组织 ID (OpenAI-Organization, 可选)" : "Organization ID (Optional)";
        public string SaveAndTest => IsChinese ? "保存并测试连接" : "Save & Test Connection";
        public string SaveAndConnect => IsChinese ? "保存并连接" : "Save & Connect";
        public string ClearKey => IsChinese ? "清除 Key" : "Clear Key";
        public string Save => IsChinese ? "保存" : "Save";
        public string Cancel => IsChinese ? "取消" : "Cancel";
        public string Close => IsChinese ? "关闭" : "Close";
        public string AddProvider => IsChinese ? "添加新厂商" : "Add Provider";
        public string EditProvider => IsChinese ? "编辑模型厂商" : "Edit Provider";
        public string QuickFillPresets => IsChinese ? "快捷预填常用国内厂商:" : "Quick Fill Domestic Presets:";
        public string ProviderNameLabel => IsChinese ? "厂商名称" : "Provider Name";
        public string ProtocolTypeLabel => IsChinese ? "接口协议类型" : "Protocol Type";
        public string DefaultModelLabel => IsChinese ? "默认模型 (可选)" : "Default Model (Optional)";
        public string NoCustomProviders => IsChinese ? "暂未添加任何国内或自定义厂商" : "No custom providers added yet";
        public string NoCustomProvidersHint => IsChinese ? "点击上方「＋ 添加新厂商」可添加硅基流动、MiniMax、腾讯混元等自定义端点。" : "Click '+ Add Provider' above to add SiliconFlow, MiniMax, etc.";
        public string AlertNotice => IsChinese ? "提示" : "Notice";

        // AccessKey Secret 读写状态（与 mac 端 I18n.swift 同名 key 保持文案一致）
        public string AlertAliyunSecretStoreFailed => IsChinese
            ? "无法写入 Windows 凭据管理器，AccessKey Secret 未能保存。TokenBar 不会把它降级存成明文 —— 请检查凭据管理器是否可用后重试。"
            : "Could not write to Windows Credential Manager, so the AccessKey Secret was not saved. TokenBar will not fall back to plain text - check that Credential Manager is available and try again.";
        public string AlertAliyunSecretDeleteFailed => IsChinese
            ? "无法从 Windows 凭据管理器删除 AccessKey Secret，本次未保存任何设置 —— 否则设置与实际凭证会不一致。请检查凭据管理器是否可用后重试。"
            : "Could not delete the AccessKey Secret from Windows Credential Manager, so nothing was saved - otherwise your settings and the stored credential would disagree. Check that Credential Manager is available and try again.";
        public string AlertAliyunSecretKeptUnreadable => IsChinese
            ? "读取不到 Windows 凭据管理器，已保留原有的 AccessKey Secret 不做改动（其余设置已保存）。若确实要清除 Secret，请先让凭据管理器恢复可读再操作。"
            : "Windows Credential Manager could not be read, so the stored AccessKey Secret was left untouched. Your other settings were saved. To actually clear the Secret, restore access first.";
        public string HintAliyunSecretLoading => IsChinese
            ? "正在从 Windows 凭据管理器读取…"
            : "Reading from Windows Credential Manager...";
        public string WarnAliyunSecretUnreadable => IsChinese
            ? "读取 Windows 凭据管理器失败。输入框为空并不表示凭据管理器里没有 Secret，保存时不会删除已存的 Secret。"
            : "Could not read Windows Credential Manager. An empty field here does not mean the credential is missing, and saving will not delete the stored Secret.";
        public string BtnRetryReadCredential => IsChinese ? "重试读取" : "Retry";
        public string AlertOk => IsChinese ? "好的" : "OK";

        // Secondary Labels
        public string DefaultCustomProviderName => IsChinese ? "OpenAI 兼容代理" : "OpenAI Compatible Proxy";
        public string FallbackCustomProviderName => IsChinese ? "自定义厂商" : "Custom Provider";

        // Hints & Section Headers
        public string HintOpenAIKey => IsChinese ? "可在 OpenAI Platform (platform.openai.com) -> API Keys 中生成。" : "Can be generated in OpenAI Platform (platform.openai.com) -> API Keys.";
        public string HintOpenAIEndpoint => IsChinese ? "默认为官方接口，亦可配置中转反向代理地址。" : "Defaults to official endpoint. Reverse proxy URLs are supported.";

        public string MethodAnthropicKey => IsChinese ? "方式一：Anthropic API Key (官方或代理)" : "Method 1: Anthropic API Key (Official or Proxy)";
        public string LabelApiEndpointColon => IsChinese ? "接入端点:" : "API Endpoint:";
        public string SaveAndTestAnthropicKey => IsChinese ? "保存并测试 API Key" : "Save & Test API Key";
        public string HintAnthropicKey => IsChinese ? "可在 Anthropic Console (console.anthropic.com) 生成。" : "Can be generated in Anthropic Console (console.anthropic.com).";
        public string MethodClaudeSubscription => IsChinese ? "方式二：Claude Code 订阅 (监控 5小时与每周额度)" : "Method 2: Claude Code Subscription (5h & Weekly Quota)";
        public string BtnReadLocalCLIAuth => IsChinese ? "读取本地 CLI 授权 (~/.claude.json)" : "Read Local CLI Auth (~/.claude.json)";
        public string LabelClaudeManualToken => IsChinese ? "手动输入 OAuth Token / Session (备用):" : "Manual OAuth Token / Session (Backup):";

        public string MethodGeminiApiKey => IsChinese ? "方式一：Google AI Studio API Key (推荐，永久有效)" : "Method 1: Google AI Studio API Key (Recommended, Lifetime)";
        public string LabelRecommendedLifetime => IsChinese ? "(推荐，永久有效)" : "(Recommended, Lifetime)";
        public string LabelGetKeyColon => IsChinese ? "获取密钥:" : "Get Key:";
        public string MethodGeminiOAuth => IsChinese ? "方式二：Google 账号授权 / 本地凭证 (Google One / Antigravity)" : "Method 2: Google Account Authorization / Local Credentials (OAuth)";
        public string BtnGoogleWebLogin => IsChinese ? "Google 网站登录授权" : "Google Web Login Authorization";
        public string BtnReadLocalGeminiConfig => IsChinese ? "读取本地 Gemini / Antigravity 配置" : "Read Local Gemini / Antigravity Credentials";
        public string LabelManualGeminiToken => IsChinese ? "手动输入 Access Token (可选):" : "Manual Access Token (Optional):";

        public string HintDeepSeekKey => IsChinese ? "可在 DeepSeek 开放平台 (platform.deepseek.com) -> API Keys 生成。" : "Can be generated in DeepSeek Platform (platform.deepseek.com) -> API Keys.";
        public string LabelDefaultModel => IsChinese ? "默认模型名称" : "Default Model Name";

        public string HintVolcengineKey => IsChinese ? "可在 火山引擎控制台 (console.volcengine.com/ark) -> API Key 管理中创建。" : "Can be created in Volcengine Console (console.volcengine.com/ark) -> API Keys.";
        public string LabelVolcengineEndpointId => IsChinese ? "模型接入点 ID (Endpoint / Model, 选填)" : "Model Endpoint ID (Endpoint / Model, Optional)";

        public string HintKimiKey => IsChinese ? "可在 Moonshot 开放平台 (platform.moonshot.cn) -> API Key 管理中创建。" : "Can be created in Moonshot Platform (platform.moonshot.cn) -> API Keys.";
        public string LabelModelName => IsChinese ? "模型名称" : "Model Name";

        public string HintGLMKey => IsChinese ? "可在 智谱开放平台 (open.bigmodel.cn) -> API Keys 中获取。" : "Can be obtained in Zhipu Platform (open.bigmodel.cn) -> API Keys.";
        public string LabelGLMKey => IsChinese ? "智谱 BigModel API Key" : "Zhipu BigModel API Key";

        public string AliyunMethodCLI => IsChinese ? "方式一：百炼官方 CLI (`bl`) (推荐)" : "Method 1: Bailian Official CLI (`bl`) (Recommended)";
        public string AliyunNoticeDesc => IsChinese ? "百炼 Token Plan 仅支持 CLI 或控制台 Cookie 读取，OpenAI 兼容接口不支持配额查询。" : "Token Plan quotas are retrieved via CLI or console cookies; OpenAI endpoints do not support quota queries.";
        public string BtnAliyunTerminalCLI => IsChinese ? "打开终端登录 CLI (`bl auth login --console`)" : "Open Terminal to Login CLI (`bl auth login --console`)";
        public string BtnAliyunTestCLI => IsChinese ? "测试 CLI 配额读取" : "Test CLI Quota Retrieval";
        public string AliyunMethodCookie => IsChinese ? "方式二：控制台网页 Cookie 授权 (备用)" : "Method 2: Console Web Cookie Authorization (Backup)";
        public string LabelAliyunCookie => IsChinese ? "控制台 Cookie:" : "Console Cookie:";
        public string BtnAliyunSaveCookie => IsChinese ? "保存 Cookie 并测试连接" : "Save Cookie & Test Connection";

        // 阿里云百炼 AK/SK 通道（与 mac 端 I18n 键一一对应）
        public string AliyunMethodAKTitle => IsChinese ? "方式一：OpenAPI AccessKey（推荐 · 多台设备可同时在线）" : "Option 1: OpenAPI AccessKey (recommended - several machines at once)";
        public string AliyunMethodAKDesc => IsChinese ? "AccessKey 是服务端凭证，不受控制台单点登录的多设备互踢影响。TokenBar 用它自动换取控制台令牌；令牌被其他设备顶掉时会静默续期。密钥保存在 Windows 凭据管理器，不写入配置文件。" : "An AccessKey is a server-side credential, so it is not affected by console single sign-on kicking other devices offline. TokenBar exchanges it for a console token and renews that token silently. The secret lives in Windows Credential Manager, never in a config file.";
        public string BtnAliyunOpenRAMConsole => IsChinese ? "前往 RAM 控制台创建" : "Create one in the RAM console";
        public string AliyunRAMHowToTitle => IsChinese ? "如何创建专用 AccessKey？" : "How do I create a dedicated AccessKey?";
        public string AliyunRAMHowToSteps => IsChinese ? "1. 用主账号登录 RAM 控制台，创建用户，登录名例如 tokenbar-monitor\n2. 访问方式只勾选「使用永久 AccessKey 访问」，不要勾控制台登录\n3. 创建后立即复制 AccessKey ID 与 Secret（Secret 只显示一次）\n4. 授权：系统策略里搜 Bailian，优先选只读策略；要显示账户余额再加财务只读 bss:DescribeAcccount\n5. 回百炼控制台，再给该用户授予对应业务空间的只读权限（RAM 权限与百炼空间权限是两套体系，都要授）\n6. 把 ID / Secret 粘贴到下方，点「保存并测试」" : "1. Sign in to the RAM console as the main account and create a user, e.g. tokenbar-monitor\n2. Under access mode tick only permanent AccessKey; leave console sign-in off\n3. Copy the AccessKey ID and Secret right away - the Secret is shown only once\n4. Grant permissions: search Bailian in the system policies and prefer a read-only one; add the read-only billing action bss:DescribeAcccount if you also want the account balance\n5. Back in the Bailian console, also grant that user read access to the workspace - RAM and Bailian workspace permissions are two separate systems\n6. Paste the ID / Secret below and press Save and test";
        public string LabelAliyunAccessKeyId => IsChinese ? "AccessKey ID:" : "AccessKey ID:";
        public string LabelAliyunAccessKeySecret => IsChinese ? "AccessKey Secret:" : "AccessKey Secret:";
        public string LabelAliyunConsoleRegion => IsChinese ? "控制台区域:" : "Console region:";
        public string LabelAliyunConsoleSite => IsChinese ? "控制台站点:" : "Console site:";
        public string AliyunAdvancedTitle => IsChinese ? "高级选项" : "Advanced";
        public string LabelAliyunSwitchAgent => IsChinese ? "代操作 UID:" : "Switch-agent UID:";
        public string HintAliyunSwitchAgent => IsChinese ? "仅企业代操作 / 子账号代管场景需要，留空即可。本机若已登录百炼 CLI，会自动带入。" : "Only needed for enterprise delegated access. Leave it blank otherwise - it is filled in automatically if the Bailian CLI is signed in on this machine.";
        public string ToggleAliyunReuseCliConfig => IsChinese ? "复用本机百炼 CLI 的登录凭证" : "Reuse credentials from the local Bailian CLI";
        public string HintAliyunReuseCliConfig => IsChinese ? "只读取 %USERPROFILE%\\.bailian\\config.json，绝不写回。开启后即使没填 AccessKey 也能直接看到额度。" : "Reads %USERPROFILE%\\.bailian\\config.json and never writes to it. With this on, quotas show up even before you add an AccessKey.";
        public string BtnAliyunSaveAndTestAK => IsChinese ? "保存并测试 AccessKey 通道" : "Save and test the AccessKey channel";
        public string LabelAliyunBalanceThreshold => IsChinese ? "账户余额提醒阈值:" : "Balance alert threshold:";
        public string AliyunMethodCLITitle => IsChinese ? "方式二：百炼 CLI（备用 · 仅单机）" : "Option 2: Bailian CLI (backup - single machine)";
        public string AliyunMethodCLIDesc => IsChinese ? "需先安装 bl 并用浏览器登录。同一账号在第二台设备登录会把第一台顶下线，不适合多机并发。" : "Requires bl to be installed and signed in through a browser. Signing in on a second machine kicks the first one offline.";
        public string AliyunMethodCookieTitle => IsChinese ? "方式三：控制台 Cookie（兜底）" : "Option 3: Console cookie (last resort)";

        public string FormTitleAddProvider => IsChinese ? "添加模型厂商" : "Add Model Provider";
        public string FormTitleEditProvider => IsChinese ? "编辑模型厂商" : "Edit Model Provider";
        public string LabelCustomBaseUrl => IsChinese ? "API 接入端点 (Base URL):" : "API Endpoint (Base URL):";
        public string LabelCustomModelOptional => IsChinese ? "默认模型名称 (选填):" : "Default Model Name (Optional):";
        public string BtnSaveProvider => IsChinese ? "保存厂商" : "Save Provider";
    }
}
