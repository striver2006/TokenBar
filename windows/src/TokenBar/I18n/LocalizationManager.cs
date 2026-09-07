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
        public string AppAboutFooter => IsChinese ? "TokenBar v1.0.0 • 模型额度监控" : "TokenBar v1.0.0 • Model Quota Monitor";
        public string SaveAllSettings => IsChinese ? "保存全部设置" : "Save All Settings";
        public string SelectPresetPrompt => IsChinese ? "选择常用厂商配置..." : "Select preset...";
        public string QuotaBadge => IsChinese ? "配额" : "Quota";
        public string RateBadge => IsChinese ? "速率" : "Rate";
        public string EnableMonitoring => IsChinese ? "启用监控" : "Enable Monitoring";

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
        public string AlertOk => IsChinese ? "好的" : "OK";

        // Placeholders & Secondary Labels
        public string PlaceholderApiKeyOpenAI => IsChinese ? "sk-... 或 sk-proj-..." : "sk-... or sk-proj-...";
        public string PlaceholderApiKeyVolcengine => IsChinese ? "sk-... 或 API Key" : "sk-... or API Key";
        public string PlaceholderApiKeyGLM => IsChinese ? "例如: 75f...your_api_key" : "e.g. 75f...your_api_key";
        public string PlaceholderApiKeyAliyun => IsChinese ? "例如: sk-sp-xxxxxxxx" : "e.g. sk-sp-xxxxxxxx";
        public string PlaceholderOrgId => IsChinese ? "org-xxxxxxxx (选填)" : "org-xxxxxxxx (Optional)";
        public string PlaceholderCustomName => IsChinese ? "例如: OpenAI 兼容代理" : "e.g. OpenAI Compatible Proxy";
        public string PlaceholderCustomModel => IsChinese ? "例如: deepseek-chat 或 claude-3-5-sonnet" : "e.g. deepseek-chat or claude-3-5-sonnet";
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
        public string PlaceholderClaudeManualToken => IsChinese ? "手动输入 OAuth Token / Session (可选备用)" : "Enter OAuth Token / Session (Optional backup)";

        public string MethodGeminiApiKey => IsChinese ? "方式一：Google AI Studio API Key (推荐，永久有效)" : "Method 1: Google AI Studio API Key (Recommended, Lifetime)";
        public string LabelRecommendedLifetime => IsChinese ? "(推荐，永久有效)" : "(Recommended, Lifetime)";
        public string LabelGetKeyColon => IsChinese ? "获取密钥:" : "Get Key:";
        public string MethodGeminiOAuth => IsChinese ? "方式二：Google 账号授权 / 本地凭证 (Google One / Antigravity)" : "Method 2: Google Account Authorization / Local Credentials (OAuth)";
        public string BtnGoogleWebLogin => IsChinese ? "Google 网站登录授权" : "Google Web Login Authorization";
        public string BtnReadLocalGeminiConfig => IsChinese ? "读取本地 Gemini / Antigravity 配置" : "Read Local Gemini / Antigravity Credentials";
        public string LabelManualGeminiToken => IsChinese ? "手动输入 Access Token (可选):" : "Manual Access Token (Optional):";
        public string PlaceholderGeminiToken => IsChinese ? "输入 Access Token" : "Enter Access Token";
        public string PlaceholderAliyunCookie => IsChinese ? "通过网页登录会自动填入，亦可手动粘贴" : "Auto-filled via web login, or paste manually";

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

        public string FormTitleAddProvider => IsChinese ? "添加模型厂商" : "Add Model Provider";
        public string FormTitleEditProvider => IsChinese ? "编辑模型厂商" : "Edit Model Provider";
        public string LabelCustomBaseUrl => IsChinese ? "API 接入端点 (Base URL):" : "API Endpoint (Base URL):";
        public string LabelCustomModelOptional => IsChinese ? "默认模型名称 (选填):" : "Default Model Name (Optional):";
        public string BtnSaveProvider => IsChinese ? "保存厂商" : "Save Provider";
    }
}
