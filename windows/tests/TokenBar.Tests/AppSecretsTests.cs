using System;
using System.Collections.Generic;
using System.Linq;
using TokenBar.Models;
using TokenBar.Services;
using Xunit;

namespace TokenBar.Tests
{
    /// <summary>
    /// 凭证字段目录与三态决策。与 mac 端 TokenBarTests 里的
    /// testAppSecretsExtractAndApplyRoundTrip / testSecretLoadActionThreeStates /
    /// testSecretSaveActionDiffAndThreeStates 对应，两端语义必须一致。
    /// </summary>
    public class AppSecretsTests
    {
        private static AppSettings SettingsWithSecrets(out Guid customId)
        {
            var custom = new CustomProviderConfig
            {
                Id = Guid.NewGuid(),
                Name = "MiMo",
                ApiKey = "mimo-key",
                ConsoleCookie = "c=1"
            };
            customId = custom.Id;
            return new AppSettings
            {
                OpenAIApiKey = " sk-openai ",
                ClaudeToken = "sk-ant-oat",
                AliyunCookie = "login_aliyunid=1",
                CustomProviders = new List<CustomProviderConfig> { custom }
            };
        }

        [Fact]
        public void Extract_TrimsValues_AndSkipsEmptyFields()
        {
            var settings = SettingsWithSecrets(out var customId);

            var extracted = AppSecrets.Extract(settings);

            Assert.Equal("sk-openai", extracted[SecretKey.OpenAIApiKey]);
            Assert.Equal("sk-ant-oat", extracted[SecretKey.ClaudeToken]);
            Assert.Equal("login_aliyunid=1", extracted[SecretKey.AliyunCookie]);
            Assert.Equal("mimo-key", extracted[SecretKey.Custom(customId, CustomSecretField.ApiKey)]);
            Assert.Equal("c=1", extracted[SecretKey.Custom(customId, CustomSecretField.ConsoleCookie)]);
            Assert.False(extracted.ContainsKey(SecretKey.GeminiApiKey));
        }

        [Fact]
        public void Apply_RestoresIntoBlankSettings()
        {
            var settings = SettingsWithSecrets(out var customId);
            var extracted = AppSecrets.Extract(settings);

            var blank = new AppSettings
            {
                CustomProviders = new List<CustomProviderConfig>
                {
                    new() { Id = customId, Name = "MiMo" }
                }
            };
            AppSecrets.Apply(extracted, blank);

            Assert.Equal("sk-openai", blank.OpenAIApiKey);
            Assert.Equal("sk-ant-oat", blank.ClaudeToken);
            Assert.Equal("mimo-key", blank.CustomProviders[0].ApiKey);
            Assert.Equal("c=1", blank.CustomProviders[0].ConsoleCookie);
        }

        [Fact]
        public void Apply_LeavesKeysAbsentFromDictionaryUntouched()
        {
            // 「字典里没有的键不动」是迁移期的关键语义：读不到的键必须保留内存里的旧明文
            var settings = new AppSettings { OpenAIApiKey = "legacy-plain" };
            AppSecrets.Apply(new Dictionary<SecretKey, string>(), settings);
            Assert.Equal("legacy-plain", settings.OpenAIApiKey);
        }

        [Fact]
        public void Keys_CoversBuiltinsPlusTwoPerCustomProvider()
        {
            var settings = SettingsWithSecrets(out var customId);

            var keys = AppSecrets.Keys(settings);

            Assert.Equal(AppSecrets.BuiltinFields.Count + 2, keys.Count);
            Assert.Contains(SecretKey.Custom(customId, CustomSecretField.ApiKey), keys);
            Assert.Contains(SecretKey.Custom(customId, CustomSecretField.ConsoleCookie), keys);
            Assert.Equal(keys.Count, keys.Distinct().Count());
        }

        [Fact]
        public void CustomKeyAccount_MatchesMacNaming()
        {
            // mac 端为 "custom.<UUID 大写>.apiKey"，两端必须同名，否则同一份凭证在两台机器上互不可见
            var id = Guid.Parse("3F2504E0-4F89-11D3-9A0C-0305E82C3301");
            Assert.Equal("custom.3F2504E0-4F89-11D3-9A0C-0305E82C3301.apiKey",
                SecretKey.Custom(id, CustomSecretField.ApiKey).Account);
            Assert.Equal("custom.3F2504E0-4F89-11D3-9A0C-0305E82C3301.consoleCookie",
                SecretKey.Custom(id, CustomSecretField.ConsoleCookie).Account);
        }

        // ---------- 启动加载三态 ----------

        [Fact]
        public void ResolveLoad_Found_PrefersStoredValue()
        {
            var action = AppSecrets.ResolveLoad(SecretLookup.Found("K"), "OLD");
            Assert.Equal(AppSecrets.LoadActionKind.UseStored, action.Kind);
            Assert.Equal("K", action.Value);
        }

        [Fact]
        public void ResolveLoad_Found_TrimsStoredValue()
        {
            // 存量值带空白时要 Trim，否则与 ResolveSave 的已 Trim 输入永远不相等，每次保存都重复写
            var action = AppSecrets.ResolveLoad(SecretLookup.Found(" K "), "");
            Assert.Equal(AppSecrets.LoadActionKind.UseStored, action.Kind);
            Assert.Equal("K", action.Value);
        }

        [Fact]
        public void ResolveLoad_AbsentWithLegacy_Migrates()
        {
            var action = AppSecrets.ResolveLoad(SecretLookup.Absent, " OLD ");
            Assert.Equal(AppSecrets.LoadActionKind.Migrate, action.Kind);
            Assert.Equal("OLD", action.Value);
        }

        [Fact]
        public void ResolveLoad_AbsentWithoutLegacy_DoesNothing()
        {
            Assert.Equal(AppSecrets.LoadActionKind.None, AppSecrets.ResolveLoad(SecretLookup.Absent, "").Kind);
            Assert.Equal(AppSecrets.LoadActionKind.None, AppSecrets.ResolveLoad(SecretLookup.Absent, null).Kind);
        }

        [Theory]
        [InlineData("OLD")]
        [InlineData("")]
        [InlineData(null)]
        public void ResolveLoad_Unavailable_NeverMigratesNorClears(string? legacy)
        {
            // 读不到时既不迁移也不清空：迁移会在凭据管理器恢复后产生重复/丢失，清空则直接删凭证
            Assert.Equal(AppSecrets.LoadActionKind.KeepLegacy,
                AppSecrets.ResolveLoad(SecretLookup.Unavailable, legacy).Kind);
        }

        // ---------- 保存差异三态 ----------

        [Fact]
        public void ResolveSave_UnchangedValue_DoesNothing()
        {
            Assert.Equal(AppSecrets.SaveActionKind.Unchanged, AppSecrets.ResolveSave("A", "A", true).Kind);
            Assert.Equal(AppSecrets.SaveActionKind.Unchanged, AppSecrets.ResolveSave(null, null, true).Kind);
            Assert.Equal(AppSecrets.SaveActionKind.Unchanged, AppSecrets.ResolveSave("  ", null, true).Kind);
        }

        [Fact]
        public void ResolveSave_ChangedValue_Writes()
        {
            var action = AppSecrets.ResolveSave(" B ", "A", true);
            Assert.Equal(AppSecrets.SaveActionKind.Write, action.Kind);
            Assert.Equal("B", action.Value);

            Assert.Equal(AppSecrets.SaveActionKind.Write, AppSecrets.ResolveSave("NEW", null, false).Kind);
        }

        [Fact]
        public void ResolveSave_ClearedInput_DeletesOnlyWhenStoreReadable()
        {
            Assert.Equal(AppSecrets.SaveActionKind.Delete, AppSecrets.ResolveSave("", "A", storeReadable: true).Kind);
            // 输入为空 + 这轮读不到 = 「没读到」而不是「要删」
            Assert.Equal(AppSecrets.SaveActionKind.KeepExisting, AppSecrets.ResolveSave("", "A", storeReadable: false).Kind);
        }
    }
}
