using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using TokenBar.I18n;
using TokenBar.Models;

namespace TokenBar.Services
{
    /// <summary>
    /// 凭据管理器（Windows Credential Manager）同步编排：启动加载 + 首启明文迁移、
    /// 保存时的差异写/删、错误态（SecretStoreErrorKind）与横幅事件。
    /// 从 RefreshManager 原样提取，日志文案、状态字段更新顺序、_secretSyncGate 的
    /// 并发语义都与原实现逐字节一致。P/Invoke 仍在 CredentialSecretStore，不在这里。
    ///
    /// 与 Settings 的关系：本类不持有 AppSettings 引用（LoadSettings 会整体替换它），
    /// 每次通过 settingsAccessor 现取；需要重写 settings.json 时通过 persistSettingsToDisk
    /// 回调 RefreshManager（内部走 SettingsStore.Save），调用时机与原实现相同。
    /// </summary>
    internal sealed class SecretSync : IDisposable
    {
        private readonly Func<AppSettings> _settingsAccessor;
        private readonly Action _persistSettingsToDisk;

        /// <summary>上次与凭据管理器对齐后的各键值；保存时据此算差异</summary>
        private Dictionary<SecretKey, string> _persistedSecrets = new();
        /// <summary>启动时读不到的键：这些键输入为空时绝不删（空只代表「没读到」）</summary>
        private HashSet<SecretKey> _unreadableSecretKeys = new();
        /// <summary>LoadFromStoreAsync 是否已跑过；之前的保存同步直接跳过，避免拿空内存去删条目</summary>
        private bool _secretsLoaded;
        /// <summary>同一时刻只允许一轮凭据写/删，避免两次保存的写与删交错</summary>
        private readonly SemaphoreSlim _secretSyncGate = new(1, 1);

        /// <summary>凭据管理器当前的错误态；null 表示正常。设置窗口据此显示橙色横幅。</summary>
        public SecretStoreErrorKind? ErrorState { get; private set; }

        /// <summary>ErrorState 变化时在 UI 线程触发</summary>
        public event Action? ErrorChanged;

        public SecretSync(Func<AppSettings> settingsAccessor, Action persistSettingsToDisk)
        {
            _settingsAccessor = settingsAccessor;
            _persistSettingsToDisk = persistSettingsToDisk;
        }

        private AppSettings Settings => _settingsAccessor();

        /// <summary>
        /// 启动时把全部凭证从凭据管理器读进 Settings，并把 settings.json 里的旧明文一次性迁进凭据管理器。
        ///
        /// 三态处理（AppSecrets.ResolveLoad）：
        /// - Found：以凭据管理器为准；
        /// - Absent + 旧明文非空：迁移（写入凭据管理器）；
        /// - Unavailable：保留内存里的旧明文，什么都不写不删，SecretsInKeychain 保持 false，
        ///   这样接下来任何一次 SaveSettings 仍会把明文写回 settings.json —— 在安全存储可用之前
        ///   绝不丢用户凭证。全部键都可信且迁移都成功后才置 true 并重写 settings.json 把明文清掉。
        /// </summary>
        public async Task LoadFromStoreAsync()
        {
            var keys = AppSecrets.Keys(Settings);
            var lookups = await CredentialSecretStore.Instance.LookupAllAsync(keys).ConfigureAwait(false);
            var legacy = AppSecrets.Extract(Settings);

            var loaded = new Dictionary<SecretKey, string>();
            var toMigrate = new Dictionary<SecretKey, string>();
            var unreadable = new HashSet<SecretKey>();
            foreach (var key in keys)
            {
                var lookup = lookups.TryGetValue(key, out var l) ? l : SecretLookup.Unavailable;
                legacy.TryGetValue(key, out var legacyValue);
                var action = AppSecrets.ResolveLoad(lookup, legacyValue);
                switch (action.Kind)
                {
                    case AppSecrets.LoadActionKind.UseStored:
                        loaded[key] = action.Value ?? string.Empty;
                        break;
                    case AppSecrets.LoadActionKind.Migrate:
                        toMigrate[key] = action.Value ?? string.Empty;
                        break;
                    case AppSecrets.LoadActionKind.KeepLegacy:
                        unreadable.Add(key);
                        break;
                    default:
                        break;
                }
            }

            var migrationFailed = false;
            foreach (var kv in toMigrate)
            {
                if (await CredentialSecretStore.Instance.SetAsync(kv.Key, kv.Value).ConfigureAwait(false))
                {
                    loaded[kv.Key] = kv.Value;
                }
                else
                {
                    migrationFailed = true;
                    Log.Error("lifecycle", $"凭证迁移写入凭据管理器失败 account={kv.Key}");
                }
            }

            AppSecrets.Apply(loaded, Settings);
            _persistedSecrets = loaded;
            _unreadableSecretKeys = unreadable;
            _secretsLoaded = true;

            var allTrustworthy = unreadable.Count == 0 && !migrationFailed;
            if (allTrustworthy != Settings.SecretsInKeychain || toMigrate.Count > 0)
            {
                Settings.SecretsInKeychain = allTrustworthy;
                // 迁移成功后重写一次 settings.json 把明文清掉；失败则保持明文落盘，下次启动重试
                _persistSettingsToDisk();
            }
            Log.Notice("lifecycle",
                $"凭证加载完成：loaded={loaded.Count} migrated={toMigrate.Count} unreadable={unreadable.Count} secretsInKeychain={allTrustworthy}");
            // 读不到与写不进是两种故障，横幅文案不同：读不到时凭证仍以旧明文运行，
            // 写不进时是迁移没能落地。两者同时出现时以「读不到」为准（更根本）。
            SetError(
                unreadable.Count > 0 ? SecretStoreErrorKind.Unavailable
                : migrationFailed ? SecretStoreErrorKind.WriteFailed
                : null);
        }

        /// <summary>
        /// 把内存里变更过的凭证同步到凭据管理器。失败时不降级明文进内存以外的地方：保留内存值、
        /// 置 ErrorState 提示用户，并把 SecretsInKeychain 打回 false 重写 settings.json 兜底，避免丢凭证。
        /// </summary>
        /// <param name="current">
        /// 凭证快照，**必须由调用方在 UI 线程上取好再传进来**。在这里现取会让线程池线程读 Settings，
        /// 与用户在设置页继续编辑形成竞态（mac 端整个流程都在 MainActor 上，天然没有这个问题）。
        /// </param>
        public async Task SyncToStoreAsync(Dictionary<SecretKey, string> current)
        {
            if (!_secretsLoaded) return;

            await _secretSyncGate.WaitAsync().ConfigureAwait(false);
            try
            {
                var keys = new HashSet<SecretKey>(current.Keys);
                keys.UnionWith(_persistedSecrets.Keys);

                var writes = new Dictionary<SecretKey, string>();
                var deletes = new List<SecretKey>();
                foreach (var key in keys)
                {
                    current.TryGetValue(key, out var cur);
                    _persistedSecrets.TryGetValue(key, out var prev);
                    var action = AppSecrets.ResolveSave(cur, prev, storeReadable: !_unreadableSecretKeys.Contains(key));
                    switch (action.Kind)
                    {
                        case AppSecrets.SaveActionKind.Write:
                            writes[key] = action.Value ?? string.Empty;
                            break;
                        case AppSecrets.SaveActionKind.Delete:
                            deletes.Add(key);
                            break;
                        default:
                            break;
                    }
                }
                if (writes.Count == 0 && deletes.Count == 0) return;

                var failed = false;
                foreach (var kv in writes)
                {
                    if (await CredentialSecretStore.Instance.SetAsync(kv.Key, kv.Value).ConfigureAwait(false))
                    {
                        _persistedSecrets[kv.Key] = kv.Value;
                        _unreadableSecretKeys.Remove(kv.Key);
                    }
                    else
                    {
                        failed = true;
                        Log.Error("lifecycle", $"凭证写入凭据管理器失败 account={kv.Key}");
                    }
                }
                foreach (var key in deletes)
                {
                    if (await CredentialSecretStore.Instance.DeleteAsync(key).ConfigureAwait(false))
                    {
                        _persistedSecrets.Remove(key);
                    }
                    else
                    {
                        failed = true;
                        Log.Error("lifecycle", $"凭证从凭据管理器删除失败 account={key}");
                    }
                }

                if (failed)
                {
                    SetError(SecretStoreErrorKind.WriteFailed);
                    if (Settings.SecretsInKeychain)
                    {
                        Settings.SecretsInKeychain = false;
                        _persistSettingsToDisk();
                    }
                }
                else if (ErrorState != null && _unreadableSecretKeys.Count == 0)
                {
                    SetError(null);
                    if (!Settings.SecretsInKeychain)
                    {
                        Settings.SecretsInKeychain = true;
                        _persistSettingsToDisk();
                    }
                }
            }
            catch (Exception ex)
            {
                Log.Error("lifecycle", $"同步凭证到凭据管理器异常: {ex}");
            }
            finally
            {
                _secretSyncGate.Release();
            }
        }

        private void SetError(SecretStoreErrorKind? kind)
        {
            if (ErrorState == kind) return;
            ErrorState = kind;
            var app = System.Windows.Application.Current;
            if (app != null && app.Dispatcher != null)
            {
                app.Dispatcher.InvokeAsync(() => ErrorChanged?.Invoke());
            }
            else
            {
                ErrorChanged?.Invoke();
            }
        }

        public void Dispose()
        {
            _secretSyncGate.Dispose();
        }
    }
}
