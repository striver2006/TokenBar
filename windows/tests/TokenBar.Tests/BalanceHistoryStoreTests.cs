using System;
using System.IO;
using TokenBar.Services;
using Xunit;

namespace TokenBar.Tests
{
    /// <summary>
    /// BalanceHistoryStore 直接读写 %LOCALAPPDATA%\TokenBar\balance_history.json。
    /// 测试只用带随机后缀的 providerKey，结束时 Clear 掉，并把原文件内容原样恢复。
    /// </summary>
    public class BalanceHistoryStoreTests : IDisposable
    {
        private static readonly string FilePath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "TokenBar", "balance_history.json");

        private readonly string? _originalContent;
        private readonly string _key = "test:" + Guid.NewGuid().ToString("N");

        public BalanceHistoryStoreTests()
        {
            _originalContent = File.Exists(FilePath) ? File.ReadAllText(FilePath) : null;
        }

        public void Dispose()
        {
            BalanceHistoryStore.Clear(_key);
            try
            {
                if (_originalContent == null)
                {
                    if (File.Exists(FilePath)) File.Delete(FilePath);
                }
                else
                {
                    File.WriteAllText(FilePath, _originalContent);
                }
            }
            catch
            {
                // 恢复失败不影响断言结果
            }
        }

        [Fact]
        public void EmptyKey_ReturnsNull()
        {
            Assert.Null(BalanceHistoryStore.GetForecastDays("", 100));
        }

        [Fact]
        public void UnknownKey_ReturnsNull()
        {
            Assert.Null(BalanceHistoryStore.GetForecastDays(_key, 100));
        }

        [Fact]
        public void TooFewSamples_ReturnsNull()
        {
            BalanceHistoryStore.Record(_key, 100);
            // 30 分钟内的重复记录会覆盖上一条，因此仍只有 1 个样本
            BalanceHistoryStore.Record(_key, 99);
            Assert.Null(BalanceHistoryStore.GetForecastDays(_key, 99));
        }

        [Fact]
        public void EnoughSamplesSpanningOverADay_ProducesForecast()
        {
            WriteSyntheticHistory(_key, new[]
            {
                (DateTime.Now.AddDays(-3), 100m),
                (DateTime.Now.AddDays(-2), 90m),
                (DateTime.Now.AddDays(-1), 80m),
                (DateTime.Now, 70m)
            });

            var days = BalanceHistoryStore.GetForecastDays(_key, 70);
            Assert.NotNull(days);
            // 3 天消耗 30 → 日均 10 → 剩 70 约 7 天
            Assert.InRange(days!.Value, 6.5, 7.5);
        }

        [Fact]
        public void NoConsumption_ReturnsNull()
        {
            WriteSyntheticHistory(_key, new[]
            {
                (DateTime.Now.AddDays(-3), 50m),
                (DateTime.Now.AddDays(-2), 60m),
                (DateTime.Now.AddDays(-1), 60m),
                (DateTime.Now, 65m)
            });
            Assert.Null(BalanceHistoryStore.GetForecastDays(_key, 65));
        }

        [Fact]
        public void ForecastIsCappedAt999Days()
        {
            WriteSyntheticHistory(_key, new[]
            {
                (DateTime.Now.AddDays(-3), 100000m),
                (DateTime.Now.AddDays(-2), 99999.9m),
                (DateTime.Now.AddDays(-1), 99999.8m),
                (DateTime.Now, 99999.7m)
            });
            var days = BalanceHistoryStore.GetForecastDays(_key, 99999.7m);
            Assert.NotNull(days);
            Assert.Equal(999, days!.Value, 3);
        }

        /// <summary>直接把合成样本写进历史文件（文件格式：{ key: [ {t, v}, ... ] }）。</summary>
        private static void WriteSyntheticHistory(string key, (DateTime T, decimal V)[] points)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            var root = File.Exists(FilePath)
                ? System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(FilePath)) as System.Text.Json.Nodes.JsonObject
                    ?? new System.Text.Json.Nodes.JsonObject()
                : new System.Text.Json.Nodes.JsonObject();

            var arr = new System.Text.Json.Nodes.JsonArray();
            foreach (var (t, v) in points)
            {
                arr.Add(new System.Text.Json.Nodes.JsonObject
                {
                    ["t"] = t,
                    ["v"] = v
                });
            }
            root[key] = arr;
            File.WriteAllText(FilePath, root.ToJsonString());
        }
    }
}
