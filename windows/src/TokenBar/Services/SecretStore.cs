using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace TokenBar.Services
{
    /// <summary>
    /// 凭据管理器条目名（TargetName = "TokenBar/" + Account）。Account 与 mac 端
    /// SecretKey.account 完全同名，两端的键目录见各自的 AppSecrets。
    ///
    /// struct 而非 enum：自定义厂商的键带 GUID，枚举表达不了。内置键以静态成员提供，
    /// 调用处写法（SecretKey.AliyunAccessKeySecret）与以前一致。
    /// </summary>
    public readonly struct SecretKey : IEquatable<SecretKey>
    {
        public string Account { get; }

        public SecretKey(string account)
        {
            if (string.IsNullOrWhiteSpace(account)) throw new ArgumentException("account 不能为空", nameof(account));
            Account = account;
        }

        public static readonly SecretKey AliyunAccessKeySecret = new("aliyunAccessKeySecret");
        public static readonly SecretKey AliyunConsoleAccessToken = new("aliyunConsoleAccessToken");

        public static readonly SecretKey OpenAIApiKey = new("openAIApiKey");
        public static readonly SecretKey AnthropicApiKey = new("anthropicApiKey");
        public static readonly SecretKey ClaudeToken = new("claudeToken");
        public static readonly SecretKey GeminiApiKey = new("geminiApiKey");
        public static readonly SecretKey GeminiToken = new("geminiToken");
        public static readonly SecretKey DeepSeekApiKey = new("deepseekApiKey");
        public static readonly SecretKey VolcengineApiKey = new("volcengineApiKey");
        public static readonly SecretKey KimiApiKey = new("kimiApiKey");
        public static readonly SecretKey OpenRouterApiKey = new("openRouterApiKey");
        public static readonly SecretKey GLMApiKey = new("glmApiKey");
        public static readonly SecretKey AliyunApiKey = new("aliyunApiKey");
        public static readonly SecretKey AliyunCookie = new("aliyunCookie");

        /// <summary>自定义厂商的字段：custom.&lt;GUID&gt;.apiKey / custom.&lt;GUID&gt;.consoleCookie。
        /// GUID 用大写 "D" 格式，与 mac 端 UUID.uuidString 一致。</summary>
        public static SecretKey Custom(Guid id, CustomSecretField field)
        {
            var suffix = field switch
            {
                CustomSecretField.ApiKey => "apiKey",
                CustomSecretField.ConsoleCookie => "consoleCookie",
                _ => throw new ArgumentOutOfRangeException(nameof(field))
            };
            return new SecretKey($"custom.{id.ToString("D").ToUpperInvariant()}.{suffix}");
        }

        public bool Equals(SecretKey other) => string.Equals(Account, other.Account, StringComparison.Ordinal);
        public override bool Equals(object? obj) => obj is SecretKey other && Equals(other);
        public override int GetHashCode() => StringComparer.Ordinal.GetHashCode(Account ?? string.Empty);
        public static bool operator ==(SecretKey a, SecretKey b) => a.Equals(b);
        public static bool operator !=(SecretKey a, SecretKey b) => !a.Equals(b);
        public override string ToString() => Account ?? string.Empty;
    }

    public enum CustomSecretField
    {
        ApiKey,
        ConsoleCookie
    }

    /// <summary>
    /// 高敏凭证的存取抽象。托管**全部**长期凭证：各厂商 API Key、Claude / Gemini 的 OAuth token、
    /// 控制台 Cookie、自定义厂商的 Key 与 Cookie，以及阿里云 AccessKey Secret / 控制台 access_token。
    /// 键目录见 AppSecrets。
    ///
    /// 以前只有阿里云两项进凭据管理器，其余明文躺在 %AppData%\TokenBar\settings.json 里 ——
    /// 任何以该用户身份运行的进程都能明文读走。
    ///
    /// 选凭据管理器而不是 System.Security.Cryptography.ProtectedData（DPAPI）：后者在
    /// .NET 8 是独立 NuGet 包，要动 csproj；而 GeminiService 已经 P/Invoke 了 CredReadW，
    /// 加上 CredWriteW / CredDeleteW 零新依赖、风格一致，且凭据管理器本身就受 DPAPI 保护。
    ///
    /// 本文件须与 mac 端 SecretStore.swift 保持行为一致。
    /// </summary>
    public interface ISecretStore
    {
        /// <summary>写入成功返回 true。凭据管理器不可用时返回 false，由调用方决定是否退回明文。</summary>
        bool Set(SecretKey key, string value);
        string? Get(SecretKey key);
        bool Delete(SecretKey key);

        /// <summary>三态读取。**有写权限的调用方（设置页）必须用这个而不是 Get。**</summary>
        SecretLookup Lookup(SecretKey key);
    }

    public enum SecretLookupKind
    {
        /// <summary>读到了非空值</summary>
        Found,
        /// <summary>确实没有：ERROR_NOT_FOUND，或条目存在但内容为空</summary>
        Absent,
        /// <summary>
        /// 这一轮没读到：超时、凭据管理器异常、访问被拒……
        /// **不表示条目不存在。** 任何「空就删掉」的推断在这个状态下都必须放弃。
        /// </summary>
        Unavailable
    }

    /// <summary>
    /// 一次凭证读取的结果。
    ///
    /// 存在的唯一理由是把「确定没有」和「读不到」分开 —— string? 表达不了这个差别，
    /// 而有写权限的调用方把两者混为一谈就是**数据丢失**：读取失败 → 输入框留空 →
    /// 用户点保存 → 走 Delete 分支 → 凭据管理器里真实存在的 AccessKey Secret 被抹掉。
    ///
    /// 刷新链路容忍「读不到」（降级成未授权，下一轮自愈）；设置页不行，它能写。
    /// 与 mac 端 SecretLookup 保持语义一致。
    /// </summary>
    public readonly record struct SecretLookup(SecretLookupKind Kind, string? Value)
    {
        public static SecretLookup Found(string value) => new(SecretLookupKind.Found, value);
        public static readonly SecretLookup Absent = new(SecretLookupKind.Absent, null);
        public static readonly SecretLookup Unavailable = new(SecretLookupKind.Unavailable, null);

        /// <summary>结果是否可以拿来做「写还是删」的判断依据</summary>
        public bool IsTrustworthy => Kind != SecretLookupKind.Unavailable;
    }

    public enum SecretSaveActionKind
    {
        /// <summary>输入框有内容 —— 写进去</summary>
        Write,
        /// <summary>输入框为空、且读取结果可信 —— 用户确实想清空</summary>
        Delete,
        /// <summary>
        /// 输入框为空、但读取结果不可信 —— 空只代表「没读到」，不代表「要删」。
        /// 保持原样，只提示用户。
        /// </summary>
        KeepExisting
    }

    /// <summary>
    /// 保存一个 secret 输入框时该做什么。抽成独立类型是因为这条分支判断错了
    /// 就是用户凭证被删，必须能被单独审阅与测试。与 mac 端 SecretSaveAction 同构。
    /// </summary>
    public readonly record struct SecretSaveAction(SecretSaveActionKind Kind, string? Value)
    {
        /// <param name="storeReadable">本次读取是否成功（Unavailable 传 false）</param>
        public static SecretSaveAction Resolve(string? input, bool storeReadable)
        {
            var trimmed = (input ?? string.Empty).Trim();
            if (trimmed.Length > 0) return new SecretSaveAction(SecretSaveActionKind.Write, trimmed);
            return new SecretSaveAction(
                storeReadable ? SecretSaveActionKind.Delete : SecretSaveActionKind.KeepExisting, null);
        }
    }

    public sealed class CredentialSecretStore : ISecretStore
    {
        public static CredentialSecretStore Instance { get; } = new CredentialSecretStore();

        private const int CRED_TYPE_GENERIC = 1;
        private const int CRED_PERSIST_LOCAL_MACHINE = 2;
        /// <summary>Win32 ERROR_NOT_FOUND：条目确实不存在，区别于其他读取失败</summary>
        private const int ERROR_NOT_FOUND = 1168;

        /// <summary>读取超时：凭据管理器一般很快，超过这个时间视为不可用</summary>
        private static readonly TimeSpan ReadTimeout = TimeSpan.FromSeconds(5);
        /// <summary>写/删超时给得更宽，写操作可能触发系统交互</summary>
        private static readonly TimeSpan WriteTimeout = TimeSpan.FromSeconds(10);

        private readonly string _prefix;

        public CredentialSecretStore(string prefix = "TokenBar/")
        {
            _prefix = prefix;
        }

        private string TargetName(SecretKey key) => _prefix + key.Account;

        // ---------- P/Invoke ----------

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredRead(string target, int type, int reservedFlag, out IntPtr credentialPtr);

        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredWrite(ref CREDENTIAL credential, int flags);

        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredDelete(string target, int type, int reservedFlag);

        [DllImport("advapi32.dll", EntryPoint = "CredFree", SetLastError = true)]
        private static extern void CredFree(IntPtr cred);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL
        {
            public int Flags;
            public int Type;
            public string TargetName;
            public string? Comment;
            public long LastWritten;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            public string? TargetAlias;
            public string UserName;
        }

        // ---------- ISecretStore ----------

        public bool Set(SecretKey key, string value)
        {
            var blob = IntPtr.Zero;
            try
            {
                var bytes = Encoding.UTF8.GetBytes(value ?? string.Empty);
                blob = Marshal.AllocHGlobal(bytes.Length);
                Marshal.Copy(bytes, 0, blob, bytes.Length);

                var cred = new CREDENTIAL
                {
                    Flags = 0,
                    Type = CRED_TYPE_GENERIC,
                    TargetName = TargetName(key),
                    Comment = "TokenBar 托管的凭证",
                    CredentialBlobSize = bytes.Length,
                    CredentialBlob = blob,
                    Persist = CRED_PERSIST_LOCAL_MACHINE,
                    AttributeCount = 0,
                    Attributes = IntPtr.Zero,
                    UserName = "TokenBar"
                };
                return CredWrite(ref cred, 0);
            }
            catch
            {
                return false;
            }
            finally
            {
                if (blob != IntPtr.Zero) Marshal.FreeHGlobal(blob);
            }
        }

        /// <summary>
        /// 同步读，保留 Win32 错误码语义。CredRead 失败时用 GetLastWin32Error 区分
        /// 「条目不存在」（ERROR_NOT_FOUND）与其他失败，绝不把后者伪装成前者。
        /// </summary>
        public SecretLookup Lookup(SecretKey key)
        {
            try
            {
                if (!CredRead(TargetName(key), CRED_TYPE_GENERIC, 0, out var ptr))
                {
                    var err = Marshal.GetLastWin32Error();
                    if (err == ERROR_NOT_FOUND) return SecretLookup.Absent;

                    Log.Error("lifecycle", $"凭据读取失败 target={key} win32Error={err}");
                    return SecretLookup.Unavailable;
                }

                try
                {
                    var cred = Marshal.PtrToStructure<CREDENTIAL>(ptr);
                    if (cred.CredentialBlobSize <= 0 || cred.CredentialBlob == IntPtr.Zero)
                        return SecretLookup.Absent;

                    var bytes = new byte[cred.CredentialBlobSize];
                    Marshal.Copy(cred.CredentialBlob, bytes, 0, cred.CredentialBlobSize);
                    var value = Encoding.UTF8.GetString(bytes);
                    return string.IsNullOrEmpty(value) ? SecretLookup.Absent : SecretLookup.Found(value);
                }
                finally
                {
                    CredFree(ptr);
                }
            }
            catch (Exception ex)
            {
                // 条目可能在、只是这次取不出来。归到「读不到」而不是「没有」——
                // 宁可让调用方保守放弃，也不能诱导它去删一个存在的条目。
                Log.Error("lifecycle", $"凭据读取异常 target={key}: {ex.Message}");
                return SecretLookup.Unavailable;
            }
        }

        /// <summary>
        /// 兼容只关心值的调用方。注意它把 Absent 和 Unavailable 抹平成 null ——
        /// **有写权限的调用方不要用它**，用 Lookup。
        /// </summary>
        public string? Get(SecretKey key) => Lookup(key).Value;

        public bool Delete(SecretKey key)
        {
            try
            {
                // 条目本来就不存在时 CredDelete 返回 false，语义上等同删除成功
                return CredDelete(TargetName(key), CRED_TYPE_GENERIC, 0)
                    || Lookup(key).Kind == SecretLookupKind.Absent;
            }
            catch
            {
                return false;
            }
        }

        // MARK: - 后台访问
        //
        // P/Invoke 的 Cred* 是同步阻塞调用。在 UI 线程上调用会卡住设置窗口；
        // 更要紧的是读取失败必须能被区分出来，否则设置页会把「读不到」当成
        // 「没有」，保存时删掉真实存在的凭证。

        /// <summary>
        /// 把一次同步凭据调用挪到线程池执行，超时后放弃等待并返回 timedOutValue。
        ///
        /// 「放弃」只是不等了：P/Invoke 不可取消，线程池上那次调用照样会跑完，
        /// 只是结果被丢弃。写操作因此可能出现「报了失败但其实写进去了」的迟到成功 ——
        /// 保守方向，调用方重试一次即可自洽。
        /// </summary>
        private static async Task<T> RunWithTimeoutAsync<T>(
            Func<T> work, TimeSpan timeout, T timedOutValue)
        {
            var task = Task.Run(work);
            using var cts = new CancellationTokenSource();
            var delay = Task.Delay(timeout, cts.Token);

            if (await Task.WhenAny(task, delay).ConfigureAwait(false) == task)
            {
                cts.Cancel();   // 回收 Task.Delay 的定时器，避免堆积
                try { return await task.ConfigureAwait(false); }
                catch { return timedOutValue; }
            }

            return timedOutValue;
        }

        /// <summary>后台读，带超时。超时/失败返回 Unavailable，**绝不伪装成 Absent**。</summary>
        public Task<SecretLookup> LookupAsync(SecretKey key) =>
            RunWithTimeoutAsync(() => Lookup(key), ReadTimeout, SecretLookup.Unavailable);

        /// <summary>批量读取超时：条目多、每条都是一次 P/Invoke，给得比单条宽</summary>
        private static readonly TimeSpan LookupAllTimeout = TimeSpan.FromSeconds(8);

        /// <summary>
        /// 一次后台读取一批 secret，逐键保留三态。整体超时 / 异常时**全部**记为 Unavailable，
        /// 绝不把「没读到」伪装成「没有」—— 启动时的凭证加载 / 迁移靠它区分
        /// 「凭据管理器里确实没有，可以把旧明文迁进去」与「读不到，什么都别动」。
        /// 与 mac 端 KeychainSecretStore.lookupAll 同语义。
        /// </summary>
        public async Task<Dictionary<SecretKey, SecretLookup>> LookupAllAsync(IReadOnlyList<SecretKey> keys)
        {
            if (keys.Count == 0) return new Dictionary<SecretKey, SecretLookup>();

            var unavailable = new Dictionary<SecretKey, SecretLookup>();
            foreach (var key in keys) unavailable[key] = SecretLookup.Unavailable;

            return await RunWithTimeoutAsync(
                () =>
                {
                    var map = new Dictionary<SecretKey, SecretLookup>();
                    foreach (var key in keys) map[key] = Lookup(key);
                    return map;
                },
                LookupAllTimeout,
                unavailable).ConfigureAwait(false);
        }

        /// <summary>
        /// 后台写，可 await 拿到结果。需要「写失败即中止、绝不降级明文」语义的
        /// 调用方必须用这个而不是 fire-and-forget。
        /// </summary>
        public Task<bool> SetAsync(SecretKey key, string value) =>
            RunWithTimeoutAsync(() => Set(key, value), WriteTimeout, false);

        /// <summary>后台删，可 await 拿到结果。条目本来就不存在算成功。</summary>
        public Task<bool> DeleteAsync(SecretKey key) =>
            RunWithTimeoutAsync(() => Delete(key), WriteTimeout, false);

        /// <summary>
        /// 在后台把一批 secret 读出来，装进内存 store 交给同步代码使用。
        ///
        /// 供刷新链路用：读不到就返回空值，让调用方走各自的降级路径，绝不为了等凭证
        /// 而卡住刷新。**有写权限的调用方不要用它** —— 它区分不了「没有」和「读不到」，
        /// 拿它的结果去决定删不删就是数据丢失，那种场景用 LookupAsync。
        /// </summary>
        public async Task<InMemorySecretStore> PrefetchAsync(params SecretKey[] keys)
        {
            var values = await RunWithTimeoutAsync(
                () =>
                {
                    var map = new Dictionary<SecretKey, string>();
                    foreach (var key in keys)
                    {
                        var r = Lookup(key);
                        if (r.Kind == SecretLookupKind.Found && r.Value != null) map[key] = r.Value;
                    }
                    return map;
                },
                ReadTimeout,
                new Dictionary<SecretKey, string>());

            if (values.Count == 0 && keys.Length > 0)
            {
                // 可能是「本来就没配」，也可能是读取失败。刷新链路对两者处置相同，
                // 这里只记一笔便于倒查，不改变行为。
                Log.Notice("lifecycle", "凭据预取未取到任何 secret（未配置或读取失败）");
            }

            var store = new InMemorySecretStore();
            foreach (var kv in values) store.Set(kv.Key, kv.Value);
            return store;
        }

        /// <summary>
        /// 后台写入，调用方不必等待。**只在不关心结果时用**；需要「写失败即中止」
        /// 语义的调用方（例如设置页保存）请用 SetAsync。
        /// </summary>
        public void SetInBackground(SecretKey key, string value)
        {
            _ = Task.Run(() =>
            {
                try { Set(key, value); }
                catch (Exception ex) { Log.Error("lifecycle", $"后台写入凭据失败 target={key}: {ex.Message}"); }
            });
        }
    }

    /// <summary>
    /// 内存实现。既供 PrefetchAsync 装载快照，也便于测试 —— 真实凭据管理器不适合
    /// 放进自动化测试。与 mac 端 InMemorySecretStore 同构。
    /// </summary>
    public sealed class InMemorySecretStore : ISecretStore
    {
        private readonly Dictionary<SecretKey, string> _storage = new();
        private readonly object _lock = new();

        /// <summary>置 true 可模拟「凭据管理器不可用」</summary>
        public bool IsUnavailable { get; set; }

        public bool Set(SecretKey key, string value)
        {
            if (IsUnavailable) return false;
            lock (_lock) { _storage[key] = value; }
            return true;
        }

        public string? Get(SecretKey key) => Lookup(key).Value;

        public bool Delete(SecretKey key)
        {
            if (IsUnavailable) return false;
            lock (_lock) { _storage.Remove(key); }
            return true;
        }

        /// <summary>
        /// IsUnavailable 必须映射成 Unavailable 而不是 Absent，否则测试覆盖到的
        /// 是错误语义（正是这个 API 要防的那个 bug）。
        /// </summary>
        public SecretLookup Lookup(SecretKey key)
        {
            if (IsUnavailable) return SecretLookup.Unavailable;
            lock (_lock)
            {
                if (_storage.TryGetValue(key, out var v) && !string.IsNullOrEmpty(v))
                    return SecretLookup.Found(v);
            }
            return SecretLookup.Absent;
        }
    }
}
