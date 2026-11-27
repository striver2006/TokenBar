using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using TokenBar.Services;
using Xunit;

namespace TokenBar.Tests
{
    /// <summary>
    /// 额度端点选择与本地 language_server 探测的解析测试。守的是「Gemini 永远 100%」那次线上事故：
    /// 两套后端各自记账，官方客户端在 daily 上消费，cloudcode-pa 上同名的桶没人动过、恒为满额；
    /// 旧逻辑 cloudcode-pa 排第一，且首个解析出 Gemini 组的响应就用。
    /// </summary>
    public class GeminiQuotaEndpointTests
    {
        private const string Daily = "https://daily-cloudcode-pa.googleapis.com";
        private const string Prod = "https://cloudcode-pa.googleapis.com";

        [Fact]
        public void DefaultOrderFollowsTheEndpointTheOfficialClientUses()
        {
            Assert.Equal(new[] { Daily, Prod }, GeminiService.OrderCloudCodeQuotaBases(null));
        }

        [Fact]
        public void ObservedOfficialEndpointMovesToFront()
        {
            Assert.Equal(new[] { Prod, Daily }, GeminiService.OrderCloudCodeQuotaBases(Prod));
            Assert.Equal(new[] { Daily, Prod }, GeminiService.OrderCloudCodeQuotaBases(Daily));

            var custom = new List<string> { "a", "b", "c" };
            Assert.Equal(new[] { "c", "a", "b" }, GeminiService.OrderCloudCodeQuotaBases("c", custom));
        }

        [Fact]
        public void UnknownHostIsNeverFollowed()
        {
            // 启动参数里出现陌生主机时不换位：access token 不送去别处
            Assert.Equal(new[] { Daily, Prod }, GeminiService.OrderCloudCodeQuotaBases("https://untrusted.example"));
        }

        [Fact]
        public void PreferredEndpointRoundTripsThroughCacheFile()
        {
            var path = Path.Combine(Path.GetTempPath(), "tokenbar-gemini-endpoint-" + Guid.NewGuid().ToString("N") + ".txt");
            try
            {
                Assert.Null(GeminiService.LoadPreferredCloudCodeBase(path));

                GeminiService.SavePreferredCloudCodeBase(path, Prod);
                Assert.Equal(Prod, GeminiService.LoadPreferredCloudCodeBase(path));

                // 文件里的空白不影响；陌生主机或损坏内容一律当作没有偏好
                File.WriteAllText(path, "  " + Daily + "\r\n");
                Assert.Equal(Daily, GeminiService.LoadPreferredCloudCodeBase(path));
                File.WriteAllText(path, "https://untrusted.example");
                Assert.Null(GeminiService.LoadPreferredCloudCodeBase(path));
            }
            finally
            {
                if (File.Exists(path)) File.Delete(path);
            }
        }

        [Fact]
        public void CommandFlagAcceptsBothArgumentForms()
        {
            // Antigravity 2.35.2 实测启动参数：命令行里有 --cloud_code_endpoint，但没有 --csrf_token
            const string current = "\"C:\\Users\\demo\\AppData\\Local\\Programs\\Antigravity\\resources\\bin\\language_server.exe\" " +
                "--standalone --override_ide_version 2.35.2 --cloud_code_endpoint https://daily-cloudcode-pa.googleapis.com " +
                "--host_bridge_url=http://127.0.0.1:58058 --read_host_bridge_token_from_stdin";
            Assert.Equal(Daily, GeminiService.MatchCommandFlag(current, "--cloud_code_endpoint", @"https?://[^\s""]+"));
            Assert.Equal("http://127.0.0.1:58058", GeminiService.MatchCommandFlag(current, "--host_bridge_url", @"https?://[^\s""]+"));
            Assert.Null(GeminiService.MatchCommandFlag(current, "--csrf_token", @"[A-Za-z0-9_\-]+"));

            // 旧版 LS：令牌在命令行上
            Assert.Equal("11111111-2222-3333-4444-555555555555",
                GeminiService.MatchCommandFlag("language_server.exe --csrf_token 11111111-2222-3333-4444-555555555555", "--csrf_token", @"[A-Za-z0-9_\-]+"));
            Assert.Equal("1111-abcd",
                GeminiService.MatchCommandFlag("language_server.exe --csrf_token=1111-abcd", "--csrf_token", @"[A-Za-z0-9_\-]+"));

            // 有参数名没有值 / 更长的参数名 / 命令行为空
            Assert.Null(GeminiService.MatchCommandFlag("language_server.exe --csrf_token", "--csrf_token", @"[A-Za-z0-9_\-]+"));
            Assert.Null(GeminiService.MatchCommandFlag("language_server.exe --csrf_token_file=C:\\tmp\\x", "--csrf_token", @"[A-Za-z0-9_\-]+"));
            Assert.Null(GeminiService.MatchCommandFlag(null, "--csrf_token", @"[A-Za-z0-9_\-]+"));
        }

        [Fact]
        public void EnvironmentBlockEntryLookupIsCaseInsensitiveAndExact()
        {
            var block = "PATH=C:\\Windows\r\nHOME=C:\\Users\\demo\0antigravity_server_csrf_token=aaaaaaaa-bbbb\0EMPTY=\0";
            Assert.Equal("C:\\Windows\r\nHOME=C:\\Users\\demo", GeminiService.FindEnvironmentVariable(block, "path"));
            Assert.Equal("aaaaaaaa-bbbb", GeminiService.FindEnvironmentVariable(block, "ANTIGRAVITY_SERVER_CSRF_TOKEN"));
            Assert.Equal("", GeminiService.FindEnvironmentVariable(block, "EMPTY"));
            // 缺的键是 null；只是前缀相同的键名、或键名只匹配到一半，都不算命中
            Assert.Null(GeminiService.FindEnvironmentVariable(block, "MISSING_KEY"));
            Assert.Null(GeminiService.FindEnvironmentVariable(block, "PATHS"));
            Assert.Null(GeminiService.FindEnvironmentVariable("HOMEPATH=C:\\Users\\demo", "HOME"));
        }

        [Fact]
        public void BlockTerminatorIsTwoUtf16Nuls()
        {
            var entries = Encoding.Unicode.GetBytes("A=1\0B=2\0");
            var terminated = Encoding.Unicode.GetBytes("A=1\0B=2\0\0");
            Assert.False(GeminiService.HasBlockTerminator(entries, 0, entries.Length), "条目之间只有一个 NUL");
            Assert.True(GeminiService.HasBlockTerminator(terminated, 0, terminated.Length));
            // 结束符跨在两块之间：从第二块开头往前多看一个字符
            var first = Encoding.Unicode.GetBytes("A=1\0B=2");
            var second = Encoding.Unicode.GetBytes("\0\0");
            var joined = new byte[first.Length + second.Length];
            Buffer.BlockCopy(first, 0, joined, 0, first.Length);
            Buffer.BlockCopy(second, 0, joined, first.Length, second.Length);
            Assert.True(GeminiService.HasBlockTerminator(joined, first.Length - 2, joined.Length));
        }

        [Fact]
        public void ReadsOwnProcessEnvironment()
        {
            // 只能验证「64 位进程读 64 位目标」这一种布局——也是 language_server 唯一的形态
            if (!Environment.Is64BitProcess) return;

            var expected = Environment.GetEnvironmentVariable("PATH");
            Assert.NotNull(expected);
            Assert.Equal(expected, GeminiService.ReadProcessEnvironmentVariable(Environment.ProcessId, "PATH"));
            Assert.Null(GeminiService.ReadProcessEnvironmentVariable(Environment.ProcessId, "TOKENBAR_DEFINITELY_MISSING_KEY"));
            // 进程不存在时拿不到，也不抛异常
            Assert.Null(GeminiService.ReadProcessEnvironmentVariable(int.MaxValue, "PATH"));
        }
    }
}
