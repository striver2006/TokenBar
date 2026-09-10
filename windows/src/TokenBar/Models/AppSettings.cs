using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace TokenBar.Models
{
    public enum AppLanguage
    {
        System,
        ZhHans,
        En
    }

    public enum ApiProtocol
    {
        OpenAIChat,
        OpenAIResponses,
        Anthropic
    }

    public class CustomProviderConfig
    {
        public Guid Id { get; set; } = Guid.NewGuid();
        public string Name { get; set; } = string.Empty;
        public bool IsEnabled { get; set; } = true;
        public string ApiKey { get; set; } = string.Empty;
        public string Endpoint { get; set; } = "http://localhost:3000/v1";
        public ApiProtocol Protocol { get; set; } = ApiProtocol.OpenAIChat;
        public string Model { get; set; } = string.Empty;
        // 余额提醒阈值（账户币种）；null 时使用默认值 10
        public decimal? BalanceAlertThreshold { get; set; }
        // 厂商控制台 Web 登录态（如小米 MiMo 的余额/Token Plan 用量查询只接受 Cookie，不接受 API Key）
        public string ConsoleCookie { get; set; } = string.Empty;

        /// <summary>去掉凭证字段后的副本，供落盘用（与 mac 端 strippingSecrets 同语义）</summary>
        public CustomProviderConfig StrippingSecrets()
        {
            var copy = (CustomProviderConfig)MemberwiseClone();
            copy.ApiKey = string.Empty;
            copy.ConsoleCookie = string.Empty;
            return copy;
        }
    }

    public class AppSettings
    {
        public int RefreshIntervalMinutes { get; set; } = 5;
        public bool EnableHover { get; set; } = true;
        public bool LaunchAtLogin { get; set; } = false;
        public AppLanguage Language { get; set; } = AppLanguage.System;

        public bool OpenAIEnabled { get; set; } = false;
        public string OpenAIApiKey { get; set; } = string.Empty;
        public string OpenAIEndpoint { get; set; } = "https://api.openai.com/v1";
        public string OpenAIOrgId { get; set; } = string.Empty;

        public bool ClaudeEnabled { get; set; } = true;
        public string AnthropicApiKey { get; set; } = string.Empty;
        public string AnthropicEndpoint { get; set; } = "https://api.anthropic.com/v1";
        public string ClaudeToken { get; set; } = string.Empty;

        public bool GeminiEnabled { get; set; } = true;
        public string GeminiApiKey { get; set; } = string.Empty;
        public string GeminiEndpoint { get; set; } = "https://generativelanguage.googleapis.com";
        public string GeminiToken { get; set; } = string.Empty;

        public bool DeepSeekEnabled { get; set; } = false;
        public string DeepSeekApiKey { get; set; } = string.Empty;
        public string DeepSeekEndpoint { get; set; } = "https://api.deepseek.com/v1";
        public string DeepSeekModel { get; set; } = "deepseek-chat";
        public decimal DeepSeekBalanceAlertThreshold { get; set; } = 10;

        public bool VolcengineEnabled { get; set; } = false;
        public string VolcengineApiKey { get; set; } = string.Empty;
        public string VolcengineEndpoint { get; set; } = "https://ark.cn-beijing.volces.com/api/v3";
        public string VolcengineModel { get; set; } = string.Empty;

        public bool KimiEnabled { get; set; } = false;
        public string KimiApiKey { get; set; } = string.Empty;
        public string KimiEndpoint { get; set; } = "https://api.moonshot.cn/v1";
        public string KimiModel { get; set; } = "moonshot-v1-8k";
        public decimal KimiBalanceAlertThreshold { get; set; } = 10;

        public bool OpenRouterEnabled { get; set; } = false;
        public string OpenRouterApiKey { get; set; } = string.Empty;
        public string OpenRouterEndpoint { get; set; } = "https://openrouter.ai/api/v1";
        public decimal OpenRouterBalanceAlertThreshold { get; set; } = 5;

        public bool GLMEnabled { get; set; } = true;
        public string GLMApiKey { get; set; } = string.Empty;
        public string GLMEndpoint { get; set; } = "https://open.bigmodel.cn/api/v1";

        public bool AliyunEnabled { get; set; } = true;
        // 历史字段：从未参与额度查询链路（百炼兼容 OpenAI 端点只能对话），
        // 仅为旧配置反序列化兼容保留，UI 已移除。
        public string AliyunApiKey { get; set; } = string.Empty;
        // 历史字段，同上。
        public string AliyunEndpoint { get; set; } = "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1";
        public string AliyunCookie { get; set; } = string.Empty;

        // 阿里云百炼 AK/SK 通道（首选，不受控制台 SSO 多设备互踢限制）。
        // AccessKey Secret 与控制台 token 不落在这里 —— 见 SecretStore（Windows 凭据管理器）。
        // 字段名与 mac 端 AppSettings 同名（大小写各随本端风格）。
        public string AliyunAccessKeyId { get; set; } = string.Empty;
        public string AliyunConsoleRegion { get; set; } = "cn-beijing";
        public string AliyunConsoleSite { get; set; } = "domestic";
        // 企业代操作 UID；0 表示未设置。阿里云 UID 可能是 16 位，必须用 64 位整数。
        public long AliyunConsoleSwitchAgent { get; set; } = 0;
        // 是否复用本机 %USERPROFILE%\.bailian\config.json 里已有的控制台凭证（只读，不写回）。
        public bool AliyunReuseCliConfig { get; set; } = true;
        // 阿里云账户现金余额提醒阈值，默认值对齐 DeepSeek / Kimi。
        public decimal AliyunBalanceAlertThreshold { get; set; } = 10;

        public List<CustomProviderConfig> CustomProviders { get; set; } = new();

        // 浮动框卡片显示顺序（键见 ProviderOrdering.DefaultOrder 与 CustomKeyPrefix）；
        // 空列表表示使用默认顺序，未列入的已启用厂商按默认顺序追加在末尾
        public List<string> ProviderOrder { get; set; } = new();

        /// <summary>
        /// 凭证是否已全部托管在 Windows 凭据管理器。为 true 时 SerializeForDisk 不再把凭证字段
        /// 写进 settings.json；为 false（首次启动、或凭据管理器读不到 / 迁移失败）时照旧写明文，
        /// 保证在安全存储可用之前**不会丢掉用户已经配好的凭证**。不参与序列化。
        /// </summary>
        [JsonIgnore]
        public bool SecretsInKeychain { get; set; } = false;

        private static readonly JsonSerializerOptions DiskOptions = new() { WriteIndented = true };

        /// <summary>
        /// 落盘用的 JSON。SecretsInKeychain 为 true 时序列化的是去掉凭证字段的副本
        /// （内置凭证字段写空串、自定义厂商逐个去掉 ApiKey / ConsoleCookie），内存里的对象保持明文不变。
        /// </summary>
        public string SerializeForDisk()
        {
            var target = SecretsInKeychain ? ForPersistence() : this;
            return JsonSerializer.Serialize(target, DiskOptions);
        }

        /// <summary>去掉全部凭证字段后的浅拷贝；CustomProviders 逐个换成 StrippingSecrets 副本。</summary>
        public AppSettings ForPersistence()
        {
            var copy = (AppSettings)MemberwiseClone();
            copy.CustomProviders = CustomProviders.Select(c => c.StrippingSecrets()).ToList();
            copy.ProviderOrder = new List<string>(ProviderOrder);
            TokenBar.Services.AppSecrets.Strip(copy);
            return copy;
        }
    }
}
