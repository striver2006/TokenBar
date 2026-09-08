using System;
using System.Windows;
using System.Windows.Media;
using Color = System.Windows.Media.Color;
using Point = System.Windows.Point;
using TokenBar.Models;

namespace TokenBar.Helpers
{
    /// <summary>
    /// 厂商标识矢量图标（对齐 macOS 端 ProviderType.iconName / SettingsTab.icon 的 SF Symbol 语义），
    /// 统一使用 24x24 viewBox 的几何图形，配合 ProviderType.GetThemeColor() 主题色呈现。
    /// </summary>
    public static class ProviderIcons
    {
        private static readonly Lazy<Geometry> HexagonLazy = new(() => Parse(
            "M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"));

        // Anthropic 官方标识为放射状星芒（macOS 端以 brain.head.profile 近似）
        private static readonly Lazy<Geometry> StarburstLazy = new(() => Parse(
            "M12 1l2.3 8.7L23 12l-8.7 2.3L12 23l-2.3-8.7L1 12l8.7-2.3z"));

        private static readonly Lazy<Geometry> SparklesLazy = new(() => Group(
            "M10 1.5C10.42 5.9 12.7 8.18 17.1 8.6 12.7 9.02 10.42 11.3 10 15.7 9.58 11.3 7.3 9.02 2.9 8.6 7.3 8.18 9.58 5.9 10 1.5z",
            "M18.6 13.8C18.83 15.9 19.98 17.05 22.1 17.28 19.98 17.51 18.83 18.66 18.6 20.76 18.37 18.66 17.22 17.51 15.1 17.28 17.22 17.05 18.37 15.9 18.6 13.8z"));

        private static readonly Lazy<Geometry> HorizontalBoltLazy = new(() => Parse(
            "M2.5 13.5 L8.5 13.5 L5 7 L20 7 L13 16 L16 16 L8 22 L11.5 14 L2.5 14 Z"));

        private static readonly Lazy<Geometry> FlameLazy = new(() => Parse(
            "M12 2C9.1 6.3 6.4 9.6 6.4 13.9 6.4 17.1 8.9 19.8 12 19.8 15.1 19.8 17.6 17.1 17.6 13.9 17.6 9.6 14.9 6.3 12 2z"));

        private static readonly Lazy<Geometry> MoonStarsLazy = new(() => Group(
            "M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z",
            "M18.8 1.8L19.5 4.1 21.8 4.8 19.5 5.5 18.8 7.8 18.1 5.5 15.8 4.8 18.1 4.1z"));

        private static readonly Lazy<Geometry> BoltLazy = new(() => Parse(
            "M13 2 L3 14 L12 14 L11 22 L21 10 L12 10 Z"));

        private static readonly Lazy<Geometry> CloudLazy = new(() => Parse(
            "M18 10h-1.26A8 8 0 1 0 9 20h9a4 4 0 0 0 0-8z"));

        // OpenRouter：信用卡造型（横条镂空），呼应纯扣费余额语义
        private static readonly Lazy<Geometry> CreditCardLazy = new(() =>
        {
            var card = new CombinedGeometry(GeometryCombineMode.Exclude,
                new RectangleGeometry(new Rect(2.5, 5, 19, 14), 2.5, 2.5),
                new RectangleGeometry(new Rect(2.5, 8.2, 19, 2.6)));
            card.Freeze();
            return card;
        });

        private static readonly Lazy<Geometry> GridLazy = new(() =>
        {
            var grid = new GeometryGroup();
            grid.Children.Add(new RectangleGeometry(new Rect(3, 3, 7.6, 7.6), 2, 2));
            grid.Children.Add(new RectangleGeometry(new Rect(13.4, 3, 7.6, 7.6), 2, 2));
            grid.Children.Add(new RectangleGeometry(new Rect(3, 13.4, 7.6, 7.6), 2, 2));
            grid.Children.Add(new RectangleGeometry(new Rect(13.4, 13.4, 7.6, 7.6), 2, 2));
            grid.Freeze();
            return grid;
        });

        private static readonly Lazy<Geometry> GearLazy = new(() =>
        {
            var discAndTeeth = new GeometryGroup();
            discAndTeeth.Children.Add(new EllipseGeometry(new Point(12, 12), 9, 9));
            for (int k = 0; k < 8; k++)
            {
                var tooth = new RectangleGeometry(new Rect(10.3, 0.8, 3.4, 5));
                tooth.Transform = new RotateTransform(k * 45, 12, 12);
                discAndTeeth.Children.Add(tooth);
            }
            var gear = new CombinedGeometry(GeometryCombineMode.Exclude, discAndTeeth,
                new EllipseGeometry(new Point(12, 12), 3.6, 3.6));
            gear.Freeze();
            return gear;
        });

        public static Geometry GetIconGeometry(ProviderType type) => type switch
        {
            ProviderType.OpenAI => HexagonLazy.Value,
            ProviderType.ClaudeCode => StarburstLazy.Value,
            ProviderType.Gemini => SparklesLazy.Value,
            ProviderType.DeepSeek => HorizontalBoltLazy.Value,
            ProviderType.Volcengine => FlameLazy.Value,
            ProviderType.Kimi => MoonStarsLazy.Value,
            ProviderType.OpenRouter => CreditCardLazy.Value,
            ProviderType.GLM => BoltLazy.Value,
            ProviderType.AliyunBailian => CloudLazy.Value,
            _ => GridLazy.Value
        };

        public static Geometry GetTabIconGeometry(SettingsTab tab) => tab switch
        {
            SettingsTab.Custom => GridLazy.Value,
            SettingsTab.General => GearLazy.Value,
            SettingsTab.OpenAI => GetIconGeometry(ProviderType.OpenAI),
            SettingsTab.Anthropic => GetIconGeometry(ProviderType.ClaudeCode),
            SettingsTab.Gemini => GetIconGeometry(ProviderType.Gemini),
            SettingsTab.DeepSeek => GetIconGeometry(ProviderType.DeepSeek),
            SettingsTab.Volcengine => GetIconGeometry(ProviderType.Volcengine),
            SettingsTab.Kimi => GetIconGeometry(ProviderType.Kimi),
            SettingsTab.OpenRouter => GetIconGeometry(ProviderType.OpenRouter),
            SettingsTab.GLM => GetIconGeometry(ProviderType.GLM),
            SettingsTab.Aliyun => GetIconGeometry(ProviderType.AliyunBailian),
            _ => GearLazy.Value
        };

        public static Color GetTabIconColor(SettingsTab tab) => tab switch
        {
            SettingsTab.OpenAI => ProviderType.OpenAI.GetThemeColor(),
            SettingsTab.Anthropic => ProviderType.ClaudeCode.GetThemeColor(),
            SettingsTab.Gemini => ProviderType.Gemini.GetThemeColor(),
            SettingsTab.DeepSeek => ProviderType.DeepSeek.GetThemeColor(),
            SettingsTab.Volcengine => ProviderType.Volcengine.GetThemeColor(),
            SettingsTab.Kimi => ProviderType.Kimi.GetThemeColor(),
            SettingsTab.OpenRouter => ProviderType.OpenRouter.GetThemeColor(),
            SettingsTab.GLM => ProviderType.GLM.GetThemeColor(),
            SettingsTab.Aliyun => ProviderType.AliyunBailian.GetThemeColor(),
            SettingsTab.Custom => Color.FromRgb(99, 102, 241),    // Indigo（与自定义厂商卡片头像一致）
            _ => Color.FromRgb(75, 85, 99)                        // Gray-600
        };

        private static Geometry Parse(string path)
        {
            var geometry = Geometry.Parse(path);
            geometry.Freeze();
            return geometry;
        }

        private static Geometry Group(params string[] paths)
        {
            var group = new GeometryGroup();
            foreach (var path in paths)
            {
                group.Children.Add(Geometry.Parse(path));
            }
            group.Freeze();
            return group;
        }
    }
}
