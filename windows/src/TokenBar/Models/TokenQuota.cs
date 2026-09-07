using System;

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
        public bool IsExpired => !IsIdle && DateTime.UtcNow >= EndTime;
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
}
