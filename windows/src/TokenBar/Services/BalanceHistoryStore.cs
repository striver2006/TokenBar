using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace TokenBar.Services
{
    /// <summary>
    /// 纯本地余额历史记录：每次刷新成功后追加一条 (时间, 余额)，
    /// 用于估算日均消耗并给出"预计可用 X 天"。
    /// 文件位于 %LOCALAPPDATA%\TokenBar\balance_history.json，保留 30 天。
    /// </summary>
    public static class BalanceHistoryStore
    {
        private class BalancePoint
        {
            [JsonPropertyName("t")]
            public DateTime T { get; set; }

            [JsonPropertyName("v")]
            public decimal V { get; set; }
        }

        private static readonly object Lock = new();
        private static readonly Lazy<string> FilePathLazy = new(() =>
        {
            var folder = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "TokenBar");
            Directory.CreateDirectory(folder);
            return Path.Combine(folder, "balance_history.json");
        });

        private const int RetentionDays = 30;
        private const double MinSampleSpanDays = 1.0;   // 样本至少跨越 24h 才估算日均消耗
        private const int MinSampleCount = 4;

        private static Dictionary<string, List<BalancePoint>> Load()
        {
            try
            {
                if (File.Exists(FilePathLazy.Value))
                {
                    var json = File.ReadAllText(FilePathLazy.Value);
                    return JsonSerializer.Deserialize<Dictionary<string, List<BalancePoint>>>(json)
                           ?? new Dictionary<string, List<BalancePoint>>();
                }
            }
            catch { }
            return new Dictionary<string, List<BalancePoint>>();
        }

        private static void Save(Dictionary<string, List<BalancePoint>> data)
        {
            try
            {
                var json = JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = false });
                File.WriteAllText(FilePathLazy.Value, json);
            }
            catch { }
        }

        /// <summary>记录一次余额读数；同 provider 距上一条不足 30 分钟时覆盖上一条。</summary>
        public static void Record(string providerKey, decimal value)
        {
            if (string.IsNullOrEmpty(providerKey)) return;
            lock (Lock)
            {
                var data = Load();
                var now = DateTime.Now;

                if (!data.TryGetValue(providerKey, out var points))
                {
                    points = new List<BalancePoint>();
                    data[providerKey] = points;
                }

                if (points.Count > 0 && (now - points[^1].T).TotalMinutes < 30)
                {
                    points[^1] = new BalancePoint { T = now, V = value };
                }
                else
                {
                    points.Add(new BalancePoint { T = now, V = value });
                }

                var cutoff = now.AddDays(-RetentionDays);
                data[providerKey] = points.Where(p => p.T >= cutoff).ToList();
                if (data[providerKey].Count == 0) data.Remove(providerKey);

                Save(data);
            }
        }

        /// <summary>
        /// 基于近 7 天历史估算日均消耗，结合当前余额推算可用天数；
        /// 样本不足（跨度 &lt; 24h 或少于 4 条）返回 null。
        /// </summary>
        public static double? GetForecastDays(string providerKey, decimal currentAmount)
        {
            if (string.IsNullOrEmpty(providerKey)) return null;
            lock (Lock)
            {
                if (!Load().TryGetValue(providerKey, out var points) || points.Count < MinSampleCount)
                    return null;

                var windowStart = DateTime.Now.AddDays(-7);
                var samples = points.Where(p => p.T >= windowStart).OrderBy(p => p.T).ToList();
                if (samples.Count < MinSampleCount) return null;

                var spanDays = (samples[^1].T - samples[0].T).TotalDays;
                if (spanDays < MinSampleSpanDays) return null;

                var consumed = samples[0].V - samples[^1].V;
                if (consumed <= 0) return null; // 期间有过充值或无消耗，不给出预测

                var dailyBurn = (double)(consumed / (decimal)spanDays);
                if (dailyBurn <= 0) return null;

                var days = currentAmount / (decimal)dailyBurn;
                return Math.Min((double)days, 999);
            }
        }

        /// <summary>清除指定厂商（或全部）历史，供删除厂商等场景使用。</summary>
        public static void Clear(string? providerKey = null)
        {
            lock (Lock)
            {
                var data = Load();
                if (providerKey == null) data.Clear(); else data.Remove(providerKey);
                Save(data);
            }
        }
    }
}
