using System;
using System.Globalization;

namespace TokenBar.Helpers
{
    /// <summary>
    /// 统一解析各厂商 x-ratelimit-reset-* / anthropic-ratelimit-*-reset 头里的「距重置时长」。
    /// 与 mac 端 RateLimitReset 语义一致：
    ///   - Go duration："20ms"、"1s"、"6m0s"、"1h2m"、"1.5s"
    ///   - 纯秒数："60"、"0.5"
    ///   - unix 秒时间戳（&gt; 1e9 视为绝对时间，换算为距今秒数）
    ///   - unix 毫秒时间戳（&gt; 1e12）
    /// 结果 clamp 到 [0, 86400]；解析失败返回 null，由调用方决定兜底值。
    /// </summary>
    public static class RateLimitReset
    {
        public const double MaxSeconds = 86400;

        public static double? Parse(string? raw)
        {
            if (string.IsNullOrWhiteSpace(raw)) return null;
            var text = raw.Trim();

            // 1. 纯数字：秒 / unix 秒 / unix 毫秒
            if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var number))
            {
                if (double.IsNaN(number) || double.IsInfinity(number)) return null;
                var nowSec = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
                double seconds;
                if (number > 1e12) seconds = number / 1000.0 - nowSec;        // 毫秒时间戳
                else if (number > 1e9) seconds = number - nowSec;             // 秒时间戳
                else seconds = number;
                return Clamp(seconds);
            }

            // 2. Go duration：依次读取 <数字><单位>
            double total = 0;
            var i = 0;
            var matchedAny = false;
            while (i < text.Length)
            {
                var start = i;
                while (i < text.Length && (char.IsDigit(text[i]) || text[i] == '.')) i++;
                if (start == i) return null; // 单位前必须有数字
                if (!double.TryParse(text.AsSpan(start, i - start), NumberStyles.Float, CultureInfo.InvariantCulture, out var value))
                    return null;

                var unitStart = i;
                while (i < text.Length && char.IsLetter(text[i])) i++;
                var unit = text.Substring(unitStart, i - unitStart).ToLowerInvariant();

                double factor = unit switch
                {
                    "ms" => 0.001,
                    "s" => 1,
                    "m" => 60,
                    "h" => 3600,
                    "d" => 86400,
                    "us" or "µs" or "ns" => 0, // 过小的单位按 0 计，仍视为合法
                    _ => double.NaN
                };
                if (double.IsNaN(factor)) return null;
                total += value * factor;
                matchedAny = true;
            }

            return matchedAny ? Clamp(total) : null;
        }

        private static double Clamp(double seconds)
        {
            if (double.IsNaN(seconds)) return 0;
            return Math.Clamp(seconds, 0, MaxSeconds);
        }
    }
}
