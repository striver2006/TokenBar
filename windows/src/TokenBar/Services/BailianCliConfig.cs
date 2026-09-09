using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.Json;

namespace TokenBar.Services
{
    /// <summary>
    /// 只读解析官方百炼 CLI (bl) 的配置文件 %USERPROFILE%\.bailian\config.json。
    ///
    /// 用途：本机若已经用 bl auth login 登录过，TokenBar 可以直接复用其中的
    /// 控制台 access_token（以及 AK/SK），省掉一次多余的 token 签发，
    /// 也让老用户零配置即可看到额度。
    ///
    /// 只读，绝不写回：CLI 用 tmp + rename 原子替换整个文件，TokenBar 并发写
    /// 会把 CLI 期间写入的其他字段（api_key、workspace_id、skill 状态等）整体覆盖掉。
    ///
    /// 本文件须与 mac 端 BailianCLIConfig.swift 保持逐行一致。
    /// </summary>
    public sealed class BailianCliConfig
    {
        public string? AccessToken { get; init; }
        public string? AccessKeyId { get; init; }
        public string? AccessKeySecret { get; init; }
        public string? ConsoleRegion { get; init; }
        public string? ConsoleSite { get; init; }
        /// <summary>阿里云 UID 可能是 16 位，必须用 64 位整数（对齐 mac 端 64 位的 Int）。</summary>
        public long? ConsoleSwitchAgent { get; init; }

        /// <summary>
        /// 配置文件所在目录：BAILIAN_CONFIG_DIR 优先，否则 %USERPROFILE%\.bailian。
        /// （与 CLI 内部的目录解析规则一致。）
        /// </summary>
        public static string ConfigDirectory(IDictionary<string, string>? environment = null)
        {
            var overrideDir = environment != null
                ? (environment.TryGetValue("BAILIAN_CONFIG_DIR", out var v) ? v : null)
                : Environment.GetEnvironmentVariable("BAILIAN_CONFIG_DIR");

            if (!string.IsNullOrWhiteSpace(overrideDir))
            {
                return overrideDir!.Trim();
            }

            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return Path.Combine(home, ".bailian");
        }

        /// <summary>读盘并解析；文件不存在或格式不对时返回 null（不是错误，只是没有可复用的凭证）。</summary>
        public static BailianCliConfig? LoadFromDisk(IDictionary<string, string>? environment = null)
        {
            try
            {
                var path = Path.Combine(ConfigDirectory(environment), "config.json");
                if (!File.Exists(path)) return null;

                using var doc = JsonDocument.Parse(File.ReadAllText(path));
                if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;
                return Parse(doc.RootElement);
            }
            catch
            {
                return null;
            }
        }

        /// <summary>
        /// 纯解析，不碰文件系统。
        ///
        /// CLI 支持多 profile：顶层 active_config 指向某个 profile 名，该名对应的
        /// 顶层字段若是对象则为 profile 段。取值优先 profile 段，缺字段回落顶层。
        /// </summary>
        public static BailianCliConfig Parse(JsonElement root)
        {
            JsonElement? profile = null;
            if (root.TryGetProperty("active_config", out var active)
                && active.ValueKind == JsonValueKind.String
                && root.TryGetProperty(active.GetString() ?? "", out var section)
                && section.ValueKind == JsonValueKind.Object)
            {
                profile = section;
            }

            string? ReadString(string key)
            {
                foreach (var source in Sources())
                {
                    if (source.TryGetProperty(key, out var el) && el.ValueKind == JsonValueKind.String)
                    {
                        var value = el.GetString()?.Trim();
                        if (!string.IsNullOrEmpty(value)) return value;
                    }
                }
                return null;
            }

            long? ReadInt(string key)
            {
                foreach (var source in Sources())
                {
                    if (!source.TryGetProperty(key, out var el)) continue;
                    if (el.ValueKind == JsonValueKind.Number && el.TryGetInt64(out var n)) return n;
                    if (el.ValueKind == JsonValueKind.String
                        && long.TryParse(el.GetString(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var s))
                    {
                        return s;
                    }
                }
                return null;
            }

            IEnumerable<JsonElement> Sources()
            {
                if (profile.HasValue) yield return profile.Value;
                yield return root;
            }

            return new BailianCliConfig
            {
                AccessToken = ReadString("access_token"),
                AccessKeyId = ReadString("access_key_id"),
                AccessKeySecret = ReadString("access_key_secret"),
                ConsoleRegion = ReadString("console_region"),
                ConsoleSite = ReadString("console_site"),
                ConsoleSwitchAgent = ReadInt("console_switch_agent")
            };
        }
    }
}
