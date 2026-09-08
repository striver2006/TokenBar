using System;
using System.Collections.Generic;

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
        public string AliyunApiKey { get; set; } = string.Empty;
        public string AliyunEndpoint { get; set; } = "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1";
        public string AliyunCookie { get; set; } = string.Empty;

        public List<CustomProviderConfig> CustomProviders { get; set; } = new();

        // 浮动框卡片显示顺序（键见 ProviderOrdering.DefaultOrder 与 CustomKeyPrefix）；
        // 空列表表示使用默认顺序，未列入的已启用厂商按默认顺序追加在末尾
        public List<string> ProviderOrder { get; set; } = new();
    }
}
