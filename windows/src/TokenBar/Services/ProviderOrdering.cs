using System;
using System.Collections.Generic;
using TokenBar.Models;

namespace TokenBar.Services
{
    /// <summary>
    /// 浮动框卡片显示顺序的键约定与排序辅助。
    /// 内置厂商使用固定小写键，自定义厂商使用 "custom:{Guid}"；
    /// AppSettings.ProviderOrder 为空表示默认顺序，未列入的厂商按默认顺序追加在末尾。
    /// </summary>
    public static class ProviderOrdering
    {
        public const string CustomKeyPrefix = "custom:";

        /// <summary>内置厂商默认顺序（与浮动框历史渲染顺序一致）。</summary>
        public static readonly string[] DefaultOrder =
        {
            "openai", "claude", "gemini", "deepseek", "volcengine",
            "kimi", "openrouter", "glm", "aliyun"
        };

        public static string CustomKey(Guid id) => CustomKeyPrefix + id;

        public static bool TryParseCustomKey(string? key, out Guid id)
        {
            id = Guid.Empty;
            return key != null
                && key.StartsWith(CustomKeyPrefix, StringComparison.Ordinal)
                && Guid.TryParse(key.AsSpan(CustomKeyPrefix.Length), out id);
        }

        /// <summary>
        /// 返回 key 的排序下标：已列入 order 则为其位置；否则排在所有已列出项之后，
        /// 内置厂商之间保持默认相对顺序、自定义厂商保持构造顺序（配合 LINQ OrderBy 的稳定排序使用）。
        /// </summary>
        public static int GetSortIndex(string key, List<string>? order)
        {
            if (order != null)
            {
                var idx = order.IndexOf(key);
                if (idx >= 0)
                {
                    return idx;
                }
            }

            var baseIndex = order?.Count ?? 0;
            var defaultIdx = Array.IndexOf(DefaultOrder, key);
            return baseIndex + (defaultIdx >= 0 ? defaultIdx : DefaultOrder.Length);
        }

        /// <summary>内置厂商的顺序键。</summary>
        public static string KeyOf(ProviderType type) => type switch
        {
            ProviderType.OpenAI => "openai",
            ProviderType.ClaudeCode => "claude",
            ProviderType.Gemini => "gemini",
            ProviderType.DeepSeek => "deepseek",
            ProviderType.Volcengine => "volcengine",
            ProviderType.Kimi => "kimi",
            ProviderType.OpenRouter => "openrouter",
            ProviderType.GLM => "glm",
            ProviderType.AliyunBailian => "aliyun",
            _ => type.ToString()
        };

        /// <summary>顺序键反查内置厂商；自定义厂商键（custom:*）返回 null。</summary>
        public static ProviderType? ParseProviderType(string key) => key switch
        {
            "openai" => ProviderType.OpenAI,
            "claude" => ProviderType.ClaudeCode,
            "gemini" => ProviderType.Gemini,
            "deepseek" => ProviderType.DeepSeek,
            "volcengine" => ProviderType.Volcengine,
            "kimi" => ProviderType.Kimi,
            "openrouter" => ProviderType.OpenRouter,
            "glm" => ProviderType.GLM,
            "aliyun" => ProviderType.AliyunBailian,
            _ => null
        };
    }
}
