using System;
using System.Collections.Generic;
using TokenBar.Models;

namespace TokenBar.Services
{
    /// <summary>
    /// AppSettings 里哪些字段是凭证、各自对应哪个凭据管理器条目，以及在内存模型与凭据管理器
    /// 之间搬运它们的纯函数。RefreshManager 启动时用它把凭据管理器读进 Settings，保存时用它
    /// 算出哪些条目要写 / 要删；AppSettings.SerializeForDisk 用它决定哪些字段不落盘。
    ///
    /// 内存中的 AppSettings 仍然持有明文（刷新链路与设置页照旧读 Settings.XxxApiKey），
    /// 只是**持久化时不再写进 settings.json**。与 mac 端 AppSecrets.swift 同构。
    /// </summary>
    public static class AppSecrets
    {
        /// <summary>内置厂商字段 ↔ 凭据管理器键</summary>
        public sealed class BuiltinField
        {
            public SecretKey Key { get; }
            public Func<AppSettings, string> Get { get; }
            public Action<AppSettings, string> Set { get; }

            public BuiltinField(SecretKey key, Func<AppSettings, string> get, Action<AppSettings, string> set)
            {
                Key = key;
                Get = get;
                Set = set;
            }
        }

        public static readonly IReadOnlyList<BuiltinField> BuiltinFields = new List<BuiltinField>
        {
            new(SecretKey.OpenAIApiKey, s => s.OpenAIApiKey, (s, v) => s.OpenAIApiKey = v),
            new(SecretKey.AnthropicApiKey, s => s.AnthropicApiKey, (s, v) => s.AnthropicApiKey = v),
            new(SecretKey.ClaudeToken, s => s.ClaudeToken, (s, v) => s.ClaudeToken = v),
            new(SecretKey.GeminiApiKey, s => s.GeminiApiKey, (s, v) => s.GeminiApiKey = v),
            new(SecretKey.GeminiToken, s => s.GeminiToken, (s, v) => s.GeminiToken = v),
            new(SecretKey.DeepSeekApiKey, s => s.DeepSeekApiKey, (s, v) => s.DeepSeekApiKey = v),
            new(SecretKey.VolcengineApiKey, s => s.VolcengineApiKey, (s, v) => s.VolcengineApiKey = v),
            new(SecretKey.KimiApiKey, s => s.KimiApiKey, (s, v) => s.KimiApiKey = v),
            new(SecretKey.OpenRouterApiKey, s => s.OpenRouterApiKey, (s, v) => s.OpenRouterApiKey = v),
            new(SecretKey.GLMApiKey, s => s.GLMApiKey, (s, v) => s.GLMApiKey = v),
            new(SecretKey.AliyunApiKey, s => s.AliyunApiKey, (s, v) => s.AliyunApiKey = v),
            new(SecretKey.AliyunCookie, s => s.AliyunCookie, (s, v) => s.AliyunCookie = v),
        };

        private static readonly CustomSecretField[] CustomFields =
        {
            CustomSecretField.ApiKey,
            CustomSecretField.ConsoleCookie
        };

        /// <summary>这份 settings 涉及的全部凭据管理器键（内置 + 每个自定义厂商两个）</summary>
        public static List<SecretKey> Keys(AppSettings settings)
        {
            var keys = new List<SecretKey>(BuiltinFields.Count + settings.CustomProviders.Count * CustomFields.Length);
            foreach (var field in BuiltinFields) keys.Add(field.Key);
            foreach (var config in settings.CustomProviders)
            {
                foreach (var field in CustomFields) keys.Add(SecretKey.Custom(config.Id, field));
            }
            return keys;
        }

        /// <summary>取出内存里非空的凭证值（去首尾空白）</summary>
        public static Dictionary<SecretKey, string> Extract(AppSettings settings)
        {
            var result = new Dictionary<SecretKey, string>();
            foreach (var field in BuiltinFields)
            {
                var v = (field.Get(settings) ?? string.Empty).Trim();
                if (v.Length > 0) result[field.Key] = v;
            }
            foreach (var config in settings.CustomProviders)
            {
                var key = (config.ApiKey ?? string.Empty).Trim();
                if (key.Length > 0) result[SecretKey.Custom(config.Id, CustomSecretField.ApiKey)] = key;
                var cookie = (config.ConsoleCookie ?? string.Empty).Trim();
                if (cookie.Length > 0) result[SecretKey.Custom(config.Id, CustomSecretField.ConsoleCookie)] = cookie;
            }
            return result;
        }

        /// <summary>把凭据管理器读到的值写回内存模型；字典里没有的键不动（保留旧明文，供迁移或降级）</summary>
        public static void Apply(IReadOnlyDictionary<SecretKey, string> values, AppSettings settings)
        {
            foreach (var field in BuiltinFields)
            {
                if (values.TryGetValue(field.Key, out var v)) field.Set(settings, v);
            }
            foreach (var config in settings.CustomProviders)
            {
                if (values.TryGetValue(SecretKey.Custom(config.Id, CustomSecretField.ApiKey), out var apiKey))
                    config.ApiKey = apiKey;
                if (values.TryGetValue(SecretKey.Custom(config.Id, CustomSecretField.ConsoleCookie), out var cookie))
                    config.ConsoleCookie = cookie;
            }
        }

        /// <summary>
        /// 把全部凭证字段清成空串（内置字段写空串而不是省略键，便于 settings.json 里旧值被覆盖清掉；
        /// 自定义厂商逐个去掉 ApiKey / ConsoleCookie）。只应作用在落盘用的副本上。
        /// </summary>
        public static void Strip(AppSettings settings)
        {
            foreach (var field in BuiltinFields) field.Set(settings, string.Empty);
            foreach (var config in settings.CustomProviders)
            {
                config.ApiKey = string.Empty;
                config.ConsoleCookie = string.Empty;
            }
        }

        // ---------- 启动加载 ----------

        public enum LoadActionKind
        {
            /// <summary>凭据管理器有值：以它为准（覆盖 settings.json 里可能残留的旧明文）</summary>
            UseStored,
            /// <summary>凭据管理器确定没有、settings.json 有旧明文：迁进凭据管理器</summary>
            Migrate,
            /// <summary>凭据管理器确定没有、settings.json 也没有：无事可做</summary>
            None,
            /// <summary>这一轮读不到：保留内存里的旧明文（可能为空），什么都不写、不删，下次启动再试</summary>
            KeepLegacy
        }

        /// <summary>启动加载时对单个键的处置。纯函数，便于单测。</summary>
        public readonly record struct LoadAction(LoadActionKind Kind, string? Value)
        {
            public static LoadAction UseStored(string value) => new(LoadActionKind.UseStored, value);
            public static LoadAction Migrate(string value) => new(LoadActionKind.Migrate, value);
            public static readonly LoadAction None = new(LoadActionKind.None, null);
            public static readonly LoadAction KeepLegacy = new(LoadActionKind.KeepLegacy, null);
        }

        public static LoadAction ResolveLoad(SecretLookup lookup, string? legacy)
        {
            var trimmed = (legacy ?? string.Empty).Trim();
            switch (lookup.Kind)
            {
                case SecretLookupKind.Found:
                    // 同样 Trim：ResolveSave 的 current 来自 Extract（已 Trim），
                    // 这里不 Trim 会让带空白的存量值每次保存都被判成「变更」而重复写入
                    return LoadAction.UseStored((lookup.Value ?? string.Empty).Trim());
                case SecretLookupKind.Absent:
                    return trimmed.Length == 0 ? LoadAction.None : LoadAction.Migrate(trimmed);
                default:
                    return LoadAction.KeepLegacy;
            }
        }

        // ---------- 保存差异 ----------

        public enum SaveActionKind
        {
            Write,
            Delete,
            /// <summary>输入为空但这一轮没读到凭据管理器：空只代表「没读到」，不代表「要删」</summary>
            KeepExisting,
            Unchanged
        }

        /// <summary>保存时对单个键的处置。</summary>
        public readonly record struct SaveAction(SaveActionKind Kind, string? Value)
        {
            public static SaveAction Write(string value) => new(SaveActionKind.Write, value);
            public static readonly SaveAction Delete = new(SaveActionKind.Delete, null);
            public static readonly SaveAction KeepExisting = new(SaveActionKind.KeepExisting, null);
            public static readonly SaveAction Unchanged = new(SaveActionKind.Unchanged, null);
        }

        /// <param name="current">内存里的当前值（null / 空 = 没有）</param>
        /// <param name="previous">上次与凭据管理器对齐后的值（null 表示没有）</param>
        /// <param name="storeReadable">该键这一轮是否读得到（Unavailable 传 false）</param>
        public static SaveAction ResolveSave(string? current, string? previous, bool storeReadable)
        {
            var cur = (current ?? string.Empty).Trim();
            var prev = previous ?? string.Empty;
            if (cur == prev) return SaveAction.Unchanged;
            if (cur.Length > 0) return SaveAction.Write(cur);
            return storeReadable ? SaveAction.Delete : SaveAction.KeepExisting;
        }
    }
}
