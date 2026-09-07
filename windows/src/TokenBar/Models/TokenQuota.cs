using System;
using System.Collections.Generic;
using System.Globalization;
using System.Windows.Media;
using Color = System.Windows.Media.Color;
using TokenBar.I18n;

namespace TokenBar.Models
{
    public enum ProviderType
    {
        OpenAI,
        ClaudeCode,
        Gemini,
        DeepSeek,
        Volcengine,
        Kimi,
        GLM,
        AliyunBailian
    }

    public static class ProviderTypeExtensions
    {
        public static string GetDisplayName(this ProviderType type) => type switch
        {
            ProviderType.OpenAI => "OpenAI",
            ProviderType.ClaudeCode => "Anthropic (Claude)",
            ProviderType.Gemini => "Google Gemini",
            ProviderType.DeepSeek => "DeepSeek (深度求索)",
            ProviderType.Volcengine => "火山方舟 (字节跳动)",
            ProviderType.Kimi => "KIMI (月之暗面)",
            ProviderType.GLM => "GLM (智谱清言)",
            ProviderType.AliyunBailian => "阿里云百炼 (Token Plan)",
            _ => type.ToString()
        };

        public static string GetShortName(this ProviderType type) => type switch
        {
            ProviderType.OpenAI => "OpenAI",
            ProviderType.ClaudeCode => "Anthropic",
            ProviderType.Gemini => "Gemini",
            ProviderType.DeepSeek => "DeepSeek",
            ProviderType.Volcengine => "火山方舟",
            ProviderType.Kimi => "KIMI",
            ProviderType.GLM => "GLM",
            ProviderType.AliyunBailian => "百炼",
            _ => type.ToString()
        };

        public static Color GetThemeColor(this ProviderType type) => type switch
        {
            ProviderType.OpenAI => Color.FromRgb(15, 166, 135),       // Teal green
            ProviderType.ClaudeCode => Color.FromRgb(217, 115, 71),   // Terracotta
            ProviderType.Gemini => Color.FromRgb(64, 133, 244),       // Google blue
            ProviderType.DeepSeek => Color.FromRgb(56, 122, 245),     // Royal Blue
            ProviderType.Volcengine => Color.FromRgb(240, 77, 56),    // Volcengine Red
            ProviderType.Kimi => Color.FromRgb(140, 89, 235),        // Moonshot Purple
            ProviderType.GLM => Color.FromRgb(59, 184, 135),         // Emerald green
            ProviderType.AliyunBailian => Color.FromRgb(255, 107, 0), // Aliyun Orange
            _ => Color.FromRgb(37, 99, 235)
        };

        public static SolidColorBrush GetThemeBrush(this ProviderType type) =>
            new SolidColorBrush(GetThemeColor(type));

        public static SettingsTab GetSettingsTab(this ProviderType type) => type switch
        {
            ProviderType.OpenAI => SettingsTab.OpenAI,
            ProviderType.ClaudeCode => SettingsTab.Anthropic,
            ProviderType.Gemini => SettingsTab.Gemini,
            ProviderType.DeepSeek => SettingsTab.DeepSeek,
            ProviderType.Volcengine => SettingsTab.Volcengine,
            ProviderType.Kimi => SettingsTab.Kimi,
            ProviderType.GLM => SettingsTab.GLM,
            ProviderType.AliyunBailian => SettingsTab.Aliyun,
            _ => SettingsTab.General
        };
    }

    public enum SettingsTab
    {
        OpenAI = 0,
        Anthropic = 1,
        Gemini = 2,
        DeepSeek = 3,
        Volcengine = 4,
        Kimi = 5,
        GLM = 6,
        Aliyun = 7,
        Custom = 8,
        General = 9
    }

    public class TokenWindow
    {
        public Guid Id { get; set; } = Guid.NewGuid();
        public string Title { get; set; } = string.Empty;
        public double UsedPercentage { get; set; }
        public DateTime StartTime { get; set; }
        public DateTime EndTime { get; set; }
        public double? UsedAmount { get; set; }
        public double? TotalLimit { get; set; }
        public string Unit { get; set; } = "%";
        public bool IsIdle { get; set; }

        public double RemainingPercentage => Math.Max(0.0, 100.0 - UsedPercentage);
        public bool IsExpired => !IsIdle && DateTime.Now >= EndTime;

        public SolidColorBrush StatusBrush
        {
            get
            {
                if (UsedPercentage >= 90)
                    return new SolidColorBrush(Color.FromRgb(239, 68, 68)); // Red
                if (UsedPercentage >= 70)
                    return new SolidColorBrush(Color.FromRgb(245, 158, 11)); // Orange
                return new SolidColorBrush(Color.FromRgb(34, 197, 94)); // Green
            }
        }

        public string TimeRemainingFormatted
        {
            get
            {
                var i18n = LocalizationManager.Instance;
                if (IsIdle || (UsedPercentage == 0.0 && DateTime.Now >= EndTime))
                {
                    return i18n.UnusedFull;
                }

                var diff = EndTime - DateTime.Now;
                if (diff.TotalSeconds <= 0)
                {
                    return i18n.ResetTimeReached;
                }

                int days = (int)diff.TotalDays;
                int hours = diff.Hours;
                int minutes = diff.Minutes;

                if (days > 0)
                    return string.Format(i18n.TimeDaysHours, days, hours);
                if (hours > 0)
                    return string.Format(i18n.TimeHoursMinutes, hours, minutes);
                return string.Format(i18n.TimeMinutes, Math.Max(1, minutes));
            }
        }

        public string TimeRangeFormatted
        {
            get
            {
                if (IsIdle)
                {
                    return LocalizationManager.Instance.FiveHourIdle;
                }

                bool isSameDay = StartTime.Date == EndTime.Date;
                if (isSameDay)
                {
                    return $"{StartTime:HH:mm} ~ {EndTime:HH:mm}";
                }
                return $"{StartTime:MM-dd HH:mm} ~ {EndTime:MM-dd HH:mm}";
            }
        }
    }

    public class ProviderQuota
    {
        public ProviderType Provider { get; set; }
        public bool IsEnabled { get; set; } = true;
        public bool IsAuthorized { get; set; }
        public string? AccountInfo { get; set; }
        public TokenWindow? FiveHourWindow { get; set; }
        public TokenWindow? WeeklyWindow { get; set; }
        public DateTime? LastUpdated { get; set; }
        public string? ErrorMessage { get; set; }
        public bool IsLoading { get; set; }
    }

    public class CustomProviderQuota
    {
        public Guid ConfigId { get; set; }
        public string Name { get; set; } = string.Empty;
        public ApiProtocol Protocol { get; set; }
        public bool IsAuthorized { get; set; }
        public string? AccountInfo { get; set; }
        public TokenWindow? PrimaryWindow { get; set; }
        public TokenWindow? SecondaryWindow { get; set; }
        public string? ErrorMessage { get; set; }
        public bool IsLoading { get; set; }
    }

    public class DomesticProviderPreset
    {
        public string Name { get; set; } = string.Empty;
        public string Endpoint { get; set; } = string.Empty;
        public ApiProtocol ApiProtocol { get; set; } = ApiProtocol.OpenAIChat;
        public string PlaceholderKey { get; set; } = "sk-...";
        public string DefaultModel { get; set; } = string.Empty;
        public string Hint { get; set; } = string.Empty;

        public static readonly List<DomesticProviderPreset> AllPresets = new()
        {
            new DomesticProviderPreset
            {
                Name = "OpenAI 兼容代理",
                Endpoint = "http://localhost:3000/v1",
                ApiProtocol = ApiProtocol.OpenAIChat,
                PlaceholderKey = "sk-...",
                DefaultModel = "gpt-4o",
                Hint = "适用于自建 OneAPI / NewAPI / 本地或第三方代理服务"
            },
            new DomesticProviderPreset
            {
                Name = "Anthropic 兼容代理",
                Endpoint = "http://localhost:8080/v1",
                ApiProtocol = ApiProtocol.Anthropic,
                PlaceholderKey = "sk-ant-...",
                DefaultModel = "claude-3-5-sonnet-20241022",
                Hint = "适用于自建或本地中转代理服务"
            },
            new DomesticProviderPreset
            {
                Name = "小米 MiMo (Xiaomi)",
                Endpoint = "https://api.xiaomimimo.com/v1",
                ApiProtocol = ApiProtocol.OpenAIChat,
                PlaceholderKey = "sk-...",
                DefaultModel = "mimo-v2.5-pro",
                Hint = "小米 MiMo 开放平台 (支持按量付费与 Token Plan)"
            },
            new DomesticProviderPreset
            {
                Name = "腾讯混元 (Tencent Hunyuan)",
                Endpoint = "https://tokenhub.tencentmaas.com/v1",
                ApiProtocol = ApiProtocol.OpenAIChat,
                PlaceholderKey = "sk-...",
                DefaultModel = "hunyuan-standard",
                Hint = "腾讯云大模型服务平台 TokenHub / 混元 API"
            },
            new DomesticProviderPreset
            {
                Name = "阶跃星辰 (StepFun)",
                Endpoint = "https://api.stepfun.com/v1",
                ApiProtocol = ApiProtocol.OpenAIChat,
                PlaceholderKey = "sk-...",
                DefaultModel = "step-1-8k",
                Hint = "阶跃星辰开放平台 (Step-1 / Step-2 系列大模型)"
            },
            new DomesticProviderPreset
            {
                Name = "硅基流动 (SiliconFlow)",
                Endpoint = "https://api.siliconflow.cn/v1",
                ApiProtocol = ApiProtocol.OpenAIChat,
                PlaceholderKey = "sk-...",
                DefaultModel = "deepseek-ai/DeepSeek-V3",
                Hint = "支持用户中心余额与全系列主流模型"
            },
            new DomesticProviderPreset
            {
                Name = "MiniMax (名之梦)",
                Endpoint = "https://api.minimax.chat/v1",
                ApiProtocol = ApiProtocol.OpenAIChat,
                PlaceholderKey = "sk-...",
                DefaultModel = "MiniMax-Text-01",
                Hint = "国内自研通用大模型平台"
            },
            new DomesticProviderPreset
            {
                Name = "零一万物 (01.AI)",
                Endpoint = "https://api.lingyiwanwu.com/v1",
                ApiProtocol = ApiProtocol.OpenAIChat,
                PlaceholderKey = "sk-...",
                DefaultModel = "yi-lightning",
                Hint = "零一万物开放平台 (Yi 系列大模型)"
            },
            new DomesticProviderPreset
            {
                Name = "百度千帆 (文心一言)",
                Endpoint = "https://qianfan.baidubce.com/v2",
                ApiProtocol = ApiProtocol.OpenAIChat,
                PlaceholderKey = "bce-v3/...",
                DefaultModel = "ernie-4.0-8k-latest",
                Hint = "百度智能云千帆大模型平台 (兼容 OpenAI 规范)"
            }
        };
    }
}
