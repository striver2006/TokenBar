using System.Windows.Media;
using Color = System.Windows.Media.Color;
using TokenBar.Models;

namespace TokenBar.Helpers
{
    /// <summary>
    /// 模型层的画刷/主题色映射。原先住在 Models/TokenQuota.cs（ProviderType.GetThemeColor /
    /// GetThemeBrush、TokenWindow.StatusBrush），导致纯数据模型依赖 System.Windows.Media；
    /// 移到 Helpers 后模型层不再引用任何 WPF 类型，画刷只在 Views/Helpers 层构造。
    /// 颜色值与阈值逐一保持原样，只是搬家。
    /// </summary>
    public static class ThemeBrushes
    {
        public static Color GetThemeColor(this ProviderType type) => type switch
        {
            ProviderType.OpenAI => Color.FromRgb(15, 166, 135),       // Teal green
            ProviderType.ClaudeCode => Color.FromRgb(217, 115, 71),   // Terracotta
            ProviderType.Gemini => Color.FromRgb(64, 133, 244),       // Google blue
            ProviderType.DeepSeek => Color.FromRgb(56, 122, 245),     // Royal Blue
            ProviderType.Volcengine => Color.FromRgb(0, 110, 255),    // Volcengine Blue（官方品牌蓝 #006EFF）
            ProviderType.Kimi => Color.FromRgb(140, 89, 235),        // Moonshot Purple
            ProviderType.OpenRouter => Color.FromRgb(100, 103, 242), // OpenRouter Indigo
            ProviderType.GLM => Color.FromRgb(59, 184, 135),         // Emerald green
            ProviderType.AliyunBailian => Color.FromRgb(255, 107, 0), // Aliyun Orange
            _ => Color.FromRgb(37, 99, 235)
        };

        public static SolidColorBrush GetThemeBrush(this ProviderType type) =>
            new SolidColorBrush(GetThemeColor(type));

        public static SolidColorBrush StatusBrush(this TokenWindow window)
        {
            if (window.Kind == TokenWindowKind.Status)
                return new SolidColorBrush(Color.FromRgb(34, 197, 94)); // Green：状态型窗口只表示连接正常

            if (window.Kind == TokenWindowKind.Balance)
            {
                if (window.BalanceAmount.HasValue && window.CriticalThreshold.HasValue && window.BalanceAmount.Value < window.CriticalThreshold.Value)
                    return new SolidColorBrush(Color.FromRgb(239, 68, 68)); // Red
                if (window.BalanceAmount.HasValue && window.WarningThreshold.HasValue && window.BalanceAmount.Value < window.WarningThreshold.Value)
                    return new SolidColorBrush(Color.FromRgb(245, 158, 11)); // Orange
                return new SolidColorBrush(Color.FromRgb(34, 197, 94)); // Green
            }

            if (window.UsedPercentage >= 90)
                return new SolidColorBrush(Color.FromRgb(239, 68, 68)); // Red
            if (window.UsedPercentage >= 70)
                return new SolidColorBrush(Color.FromRgb(245, 158, 11)); // Orange
            return new SolidColorBrush(Color.FromRgb(34, 197, 94)); // Green
        }
    }
}
