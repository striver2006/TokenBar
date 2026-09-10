using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;

namespace TokenBar.Services
{
    /// <summary>
    /// 进程内共享的 HttpClient。
    ///
    /// 以前每个服务各自 new 一个 HttpClient：连接池互相隔离、DNS 变更后连接不轮换。
    /// 统一到这里：SocketsHttpHandler 5 分钟轮换连接、12 秒连接超时；
    /// Timeout 30s 是端到端总超时，单厂商预算由 RefreshManager 的 CancellationToken 再收紧。
    /// </summary>
    public static class Http
    {
        public static readonly HttpClient Shared = Create();

        private static HttpClient Create()
        {
            var handler = new SocketsHttpHandler
            {
                PooledConnectionLifetime = TimeSpan.FromMinutes(5),
                ConnectTimeout = TimeSpan.FromSeconds(12),
                AutomaticDecompression = System.Net.DecompressionMethods.All
            };
            var client = new HttpClient(handler)
            {
                Timeout = TimeSpan.FromSeconds(30)
            };
            client.DefaultRequestHeaders.UserAgent.Clear();
            client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("TokenBar", AppVersion.Short));
            return client;
        }
    }

    /// <summary>版本号单源：来自 TokenBar.csproj 的 &lt;Version&gt;（AssemblyInformationalVersion）。</summary>
    public static class AppVersion
    {
        /// <summary>例如 "1.1.1"。取不到时回退 "0.0.0"。</summary>
        public static string Short { get; } = Resolve();

        private static string Resolve()
        {
            try
            {
                var asm = Assembly.GetExecutingAssembly();
                var info = asm.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
                if (!string.IsNullOrWhiteSpace(info))
                {
                    // SDK 会在 InformationalVersion 后追加 "+<commit>"，只取前面的语义化版本
                    var plus = info.IndexOf('+');
                    return plus > 0 ? info.Substring(0, plus) : info;
                }
                var v = asm.GetName().Version;
                if (v != null) return $"{v.Major}.{v.Minor}.{v.Build}";
            }
            catch (Exception ex)
            {
                Log.Warn("lifecycle", $"读取程序集版本失败: {ex.Message}");
            }
            return "0.0.0";
        }
    }
}
