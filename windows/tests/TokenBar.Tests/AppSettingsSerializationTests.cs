using System;
using System.Collections.Generic;
using System.Text.Json;
using TokenBar.Models;
using Xunit;

namespace TokenBar.Tests
{
    /// <summary>
    /// settings.json 的凭证落盘策略。对应 mac 端
    /// testAppSettingsEncodingOmitsSecretsOnlyWhenInKeychain。
    /// </summary>
    public class AppSettingsSerializationTests
    {
        private static AppSettings WithSecrets() => new()
        {
            OpenAIApiKey = "sk-openai",
            GeminiToken = "ya29.x",
            AliyunCookie = "login_aliyunid=1",
            CustomProviders = new List<CustomProviderConfig>
            {
                new() { Name = "X", ApiKey = "custom-key", ConsoleCookie = "cookie-value", Endpoint = "https://example.com/v1" }
            }
        };

        [Fact]
        public void NotYetMigrated_KeepsPlainTextOnDisk()
        {
            // 凭据管理器可用之前必须继续写明文，否则用户已配好的凭证会在一次保存后消失
            var settings = WithSecrets();
            settings.SecretsInKeychain = false;

            var json = settings.SerializeForDisk();

            Assert.Contains("sk-openai", json);
            Assert.Contains("custom-key", json);
            Assert.Contains("cookie-value", json);
        }

        [Fact]
        public void Migrated_WritesNoSecretToDisk()
        {
            var settings = WithSecrets();
            settings.SecretsInKeychain = true;

            var json = settings.SerializeForDisk();

            Assert.DoesNotContain("sk-openai", json);
            Assert.DoesNotContain("ya29.x", json);
            Assert.DoesNotContain("login_aliyunid=1", json);
            Assert.DoesNotContain("custom-key", json);
            Assert.DoesNotContain("cookie-value", json);
        }

        [Fact]
        public void Migrated_KeepsNonSecretFieldsAndStructure()
        {
            var settings = WithSecrets();
            settings.SecretsInKeychain = true;

            var decoded = JsonSerializer.Deserialize<AppSettings>(settings.SerializeForDisk());

            Assert.NotNull(decoded);
            Assert.Single(decoded!.CustomProviders);
            Assert.Equal("X", decoded.CustomProviders[0].Name);
            Assert.Equal("https://example.com/v1", decoded.CustomProviders[0].Endpoint);
            Assert.Equal(string.Empty, decoded.CustomProviders[0].ApiKey);
            Assert.Equal(string.Empty, decoded.OpenAIApiKey);
            // 标志本身不落盘：启动后由凭据管理器的加载结果重新决定
            Assert.False(decoded.SecretsInKeychain);
        }

        [Fact]
        public void SerializeForDisk_DoesNotMutateInMemorySettings()
        {
            // 落盘走的是副本；内存对象必须保持明文，否则刷新链路马上就没凭证可用了
            var settings = WithSecrets();
            settings.SecretsInKeychain = true;

            settings.SerializeForDisk();

            Assert.Equal("sk-openai", settings.OpenAIApiKey);
            Assert.Equal("custom-key", settings.CustomProviders[0].ApiKey);
            Assert.Equal("cookie-value", settings.CustomProviders[0].ConsoleCookie);
        }
    }
}
