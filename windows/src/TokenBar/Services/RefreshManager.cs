using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Timer = System.Threading.Timer;
using TokenBar.I18n;
using TokenBar.Models;
using TokenBar.Tray;

namespace TokenBar.Services
{
    /// <summary>一轮刷新的触发来源，只用于日志定位（"到底是定时器没响，还是每轮都失败"）</summary>
    public enum RefreshTrigger
    {
        Initial,   // App 启动首刷
        Timer,     // 周期定时器
        Manual,    // 托盘菜单 / 弹窗刷新按钮
        Wake,      // 系统唤醒补刷
        Settings   // 设置变更后立即刷新
    }

    /// <summary>凭据管理器错误态，设置窗口据此选择横幅文案</summary>
    public enum SecretStoreErrorKind
    {
        /// <summary>启动时读不到：凭证暂以旧明文运行，不清除不迁移</summary>
        Unavailable,
        /// <summary>保存时写/删失败：已打回明文落盘兜底</summary>
        WriteFailed
    }

    public class RefreshManager : IDisposable
    {
        public static RefreshManager Instance { get; } = new RefreshManager();

        public AppSettings Settings { get; private set; } = new();
        public Dictionary<ProviderType, ProviderQuota> Quotas { get; } = new();
        public ConcurrentDictionary<Guid, CustomProviderQuota> CustomQuotas { get; } = new();
        public bool IsRefreshing => Volatile.Read(ref _refreshing) == 1;
        public DateTime? LastRefreshDate { get; private set; }

        // 0 = 空闲，1 = 刷新中。定时器回调在线程池线程、手动刷新在 UI 线程，
        // 无锁的 check-then-set 会让两者同时通过检查并发跑两轮全量刷新。
        private int _refreshing;

        // 本轮开始时刻（UTC ticks，0 表示空闲）。闸门卡死时用它判断是否该强制抢占。
        private long _refreshStartedAtTicks;
        // 轮次代数：被抢占的旧轮次结束时不能把新轮次的闸门误清掉。
        private long _refreshGeneration;
        // 上一次定时器触发的时刻，用于在日志里暴露真实间隔
        private DateTime? _lastTimerFire;

        // 闸门抢占阈值。有了单厂商超时隔离后一轮最多约 35s 返回，
        // 90s 纯粹是兜底：防住子进程这类不响应取消的路径。
        private static readonly TimeSpan GateStaleThreshold = TimeSpan.FromSeconds(90);

        /// <summary>最近一次"发起过刷新"的时刻，无论成败都推进。</summary>
        public DateTime? LastAttemptDate { get; private set; }
        /// <summary>最近一轮是否拿到了新数据，用于让"刷新了但全失败"对用户可见。</summary>
        public bool LastRoundAdvanced { get; private set; }

        private Timer? _timer;
        // 当前定时器生效的间隔，用于判断设置变更是否真的需要重建定时器
        private int? _activeIntervalMinutes;
        private readonly string _configFilePath;

        // 余额窗口的展示辅助状态（较上次差值 + 低余额提醒状态机），进程内有效
        private readonly object _balanceLock = new();
        private readonly Dictionary<string, decimal> _lastBalance = new();
        private readonly HashSet<string> _balanceAlerted = new();

        public event Action? OnQuotasUpdated;

        // ---------- 凭证托管状态（与 mac 端 RefreshManager 的 persistedSecrets / unreadableSecretKeys 同构） ----------

        /// <summary>上次与凭据管理器对齐后的各键值；保存时据此算差异</summary>
        private Dictionary<SecretKey, string> _persistedSecrets = new();
        /// <summary>启动时读不到的键：这些键输入为空时绝不删（空只代表「没读到」）</summary>
        private HashSet<SecretKey> _unreadableSecretKeys = new();
        /// <summary>LoadSecretsFromStoreAsync 是否已跑过；之前的 SaveSettings 不做同步，避免拿空内存去删条目</summary>
        private bool _secretsLoaded;
        /// <summary>同一时刻只允许一轮凭据写/删，避免两次保存的写与删交错</summary>
        private readonly SemaphoreSlim _secretSyncGate = new(1, 1);

        /// <summary>凭据管理器当前的错误态；null 表示正常。设置窗口据此显示橙色横幅。</summary>
        public SecretStoreErrorKind? SecretStoreErrorState { get; private set; }

        /// <summary>SecretStoreErrorState 对应的本地化文案（随当前语言变化），null 表示没有错误</summary>
        public string? SecretStoreError => SecretStoreErrorState switch
        {
            SecretStoreErrorKind.Unavailable => LocalizationManager.Instance.WarnSecretStoreUnavailable,
            SecretStoreErrorKind.WriteFailed => LocalizationManager.Instance.WarnSecretStoreWriteFailed,
            _ => null
        };

        /// <summary>SecretStoreErrorState 变化时在 UI 线程触发</summary>
        public event Action? OnSecretStoreErrorChanged;

        private RefreshManager()
        {
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            var folder = Path.Combine(appData, "TokenBar");
            Directory.CreateDirectory(folder);
            _configFilePath = Path.Combine(folder, "settings.json");
        }

        public void Initialize()
        {
            LoadSettings();

            foreach (ProviderType type in Enum.GetValues(typeof(ProviderType)))
            {
                Quotas[type] = new ProviderQuota { Provider = type };
            }

            foreach (var config in Settings.CustomProviders)
            {
                CustomQuotas[config.Id] = new CustomProviderQuota
                {
                    ConfigId = config.Id,
                    Name = config.Name,
                    Protocol = config.Protocol
                };
            }

            SetupInitialData();
            // 定时器必须先于首刷创建：首刷一旦挂起，定时器不存在就永远没有自动刷新
            StartTimer();
            Log.Notice("lifecycle", $"TokenBar 启动，refreshInterval={Settings.RefreshIntervalMinutes}min");
            _ = LoadSecretsThenInitialRefreshAsync();
        }

        /// <summary>凭证必须先于首刷从凭据管理器读进内存，否则首轮全部厂商都会被判成未配置</summary>
        private async Task LoadSecretsThenInitialRefreshAsync()
        {
            try
            {
                await LoadSecretsFromStoreAsync().ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                // 加载失败不能拦住首刷：内存里仍是 settings.json 的旧明文，照常刷新
                Log.Error("lifecycle", $"启动加载凭证异常: {ex}");
            }
            await RefreshAllAsync(RefreshTrigger.Initial).ConfigureAwait(false);
        }

        // MARK: - 凭证与凭据管理器

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
        public async Task LoadSecretsFromStoreAsync()
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
                PersistSettingsToDisk();
            }
            Log.Notice("lifecycle",
                $"凭证加载完成：loaded={loaded.Count} migrated={toMigrate.Count} unreadable={unreadable.Count} secretsInKeychain={allTrustworthy}");
            // 读不到与写不进是两种故障，横幅文案不同：读不到时凭证仍以旧明文运行，
            // 写不进时是迁移没能落地。两者同时出现时以「读不到」为准（更根本）。
            SetSecretStoreError(
                unreadable.Count > 0 ? SecretStoreErrorKind.Unavailable
                : migrationFailed ? SecretStoreErrorKind.WriteFailed
                : null);
        }

        /// <summary>
        /// 把内存里变更过的凭证同步到凭据管理器。失败时不降级明文进内存以外的地方：保留内存值、
        /// 置 SecretStoreErrorState 提示用户，并把 SecretsInKeychain 打回 false 重写 settings.json 兜底，避免丢凭证。
        /// </summary>
        /// <param name="current">
        /// 凭证快照，**必须由调用方在 UI 线程上取好再传进来**。在这里现取会让线程池线程读 Settings，
        /// 与用户在设置页继续编辑形成竞态（mac 端整个流程都在 MainActor 上，天然没有这个问题）。
        /// </param>
        private async Task SyncSecretsToStoreAsync(Dictionary<SecretKey, string> current)
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
                    SetSecretStoreError(SecretStoreErrorKind.WriteFailed);
                    if (Settings.SecretsInKeychain)
                    {
                        Settings.SecretsInKeychain = false;
                        PersistSettingsToDisk();
                    }
                }
                else if (SecretStoreErrorState != null && _unreadableSecretKeys.Count == 0)
                {
                    SetSecretStoreError(null);
                    if (!Settings.SecretsInKeychain)
                    {
                        Settings.SecretsInKeychain = true;
                        PersistSettingsToDisk();
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

        private void SetSecretStoreError(SecretStoreErrorKind? kind)
        {
            if (SecretStoreErrorState == kind) return;
            SecretStoreErrorState = kind;
            var app = System.Windows.Application.Current;
            if (app != null && app.Dispatcher != null)
            {
                app.Dispatcher.InvokeAsync(() => OnSecretStoreErrorChanged?.Invoke());
            }
            else
            {
                OnSecretStoreErrorChanged?.Invoke();
            }
        }

        private void SetupInitialData()
        {
            // Auto-detect local Claude if available
            var localClaude = ClaudeService.Instance.ReadLocalClaudeJson();
            if (localClaude != null)
            {
                var q = Quotas[ProviderType.ClaudeCode];
                q.IsAuthorized = true;
                q.AccountInfo = localClaude.Value.Account;
                q.FiveHourWindow = localClaude.Value.FiveHour;
                q.WeeklyWindow = localClaude.Value.Weekly;
                q.LastUpdated = DateTime.Now;
            }

            // Auto-detect local Gemini if available
            var localGemini = GeminiService.Instance.ReadLocalGeminiConfig();
            if (localGemini.Token != null || localGemini.Account != null)
            {
                var q = Quotas[ProviderType.Gemini];
                q.IsAuthorized = true;
                q.AccountInfo = localGemini.Account;
                q.LastUpdated = DateTime.Now;
            }
        }

        public void LoadSettings()
        {
            try
            {
                if (File.Exists(_configFilePath))
                {
                    var json = File.ReadAllText(_configFilePath);
                    var loaded = JsonSerializer.Deserialize<AppSettings>(json);
                    if (loaded != null) Settings = loaded;
                }
            }
            catch (Exception ex)
            {
                // 读坏了的配置不能原地覆盖：改名保留现场，用户还能从里面把 API Key 抄回来
                Settings = new AppSettings();
                Log.Error("settings", $"settings.json 读取失败，已改名保留: {ex.Message}");
                try
                {
                    var corrupt = _configFilePath + ".corrupt-" + DateTime.Now.ToString("yyyyMMddHHmmss");
                    File.Move(_configFilePath, corrupt, overwrite: true);
                    Log.Error("settings", $"损坏文件已改名为 {Path.GetFileName(corrupt)}");
                }
                catch (Exception moveEx)
                {
                    Log.Error("settings", $"改名损坏的 settings.json 失败: {moveEx.Message}");
                }
            }

            LocalizationManager.Instance.CurrentLanguage = Settings.Language;
        }

        private readonly object _saveLock = new();

        /// <summary>只写 settings.json（凭证字段是否落盘由 Settings.SecretsInKeychain 决定），不碰凭据管理器</summary>
        private void PersistSettingsToDisk()
        {
            try
            {
                // SerializeForDisk 在 SecretsInKeychain 时序列化的是去掉凭证的副本，内存对象保持明文
                var json = Settings.SerializeForDisk();
                // 先写临时文件再原子替换：进程在写到一半时被杀，不会留下半截 JSON
                lock (_saveLock)
                {
                    var tmp = _configFilePath + ".tmp";
                    File.WriteAllText(tmp, json);
                    File.Move(tmp, _configFilePath, overwrite: true);
                }
            }
            catch (Exception ex)
            {
                Log.Error("settings", $"settings.json 写入失败: {ex.Message}");
            }
        }

        public void SaveSettings()
        {
            PersistSettingsToDisk();
            // 凭证差异写入凭据管理器在后台进行；失败会置 SecretStoreErrorState 并把明文重写回 settings.json 兜底。
            // 快照在这里（调用线程）取，后台任务只用这份不可变副本。
            _ = SyncSecretsToStoreAsync(AppSecrets.Extract(Settings));

            try
            {
                LocalizationManager.Instance.CurrentLanguage = Settings.Language;
                // 只有间隔真的变了才重建定时器：设置页里切厂商开关、改语言等都会走到这里，
                // 每次都 Dispose 重建会把计时相位打回零，间隔较长时可能永远刷不到。
                if (_activeIntervalMinutes != Settings.RefreshIntervalMinutes)
                {
                    StartTimer();
                }
            }
            catch (Exception ex)
            {
                Log.Error("settings", $"应用设置失败: {ex.Message}");
            }
        }

        public void StartTimer()
        {
            _timer?.Dispose();
            var interval = Math.Max(1, Settings.RefreshIntervalMinutes);
            _timer = new Timer(TimerTickAsync, null, TimeSpan.FromMinutes(interval), TimeSpan.FromMinutes(interval));
            _activeIntervalMinutes = Settings.RefreshIntervalMinutes;
            _lastTimerFire = null;
            Log.Notice("timer", $"定时器已创建：interval={interval}min");
        }

        // TimerCallback 返回 void，异常一旦逃出这个 async void 方法就会终止进程，
        // 因此这里必须吞掉所有异常（各厂商方法内部已各自记录错误信息）。
        private async void TimerTickAsync(object? state)
        {
            try
            {
                // 距上次触发的真实间隔是判断"定时器是否被系统挂起拉长"的关键指标
                if (_lastTimerFire is DateTime previous)
                {
                    Log.Notice("timer", $"timer fired，距上次 {(DateTime.Now - previous).TotalSeconds:F1}s");
                }
                else
                {
                    Log.Notice("timer", "timer fired（本定时器首次触发）");
                }
                _lastTimerFire = DateTime.Now;

                await RefreshAllAsync(RefreshTrigger.Timer);
            }
            catch (Exception ex)
            {
                Log.Error("timer", $"定时刷新回调异常: {ex}");
            }
        }

        /// <summary>数据过期时才刷新，用于系统唤醒这类"可能已经错过若干个周期"的补刷场景</summary>
        public async Task RefreshIfStaleAsync(TimeSpan olderThan)
        {
            // 唤醒事件可能连续到达，60 秒内只认一次
            if (LastAttemptDate is DateTime attempt && DateTime.Now - attempt < TimeSpan.FromSeconds(60))
            {
                Log.Debug("lifecycle", "跳过唤醒补刷：刚刚已尝试过");
                return;
            }
            // 判据是 LastRefreshDate（最近一次真的拿到数据），全失败轮次不会推进它，
            // 所以补刷不会被"刷过但没成功"骗过去。
            if (LastRefreshDate is DateTime last && DateTime.Now - last < olderThan) return;

            var age = LastRefreshDate.HasValue ? (DateTime.Now - LastRefreshDate.Value).TotalSeconds : -1;
            Log.Notice("lifecycle", $"唤醒补刷，dataAge={age:F0}s");
            await RefreshAllAsync(RefreshTrigger.Wake);
        }

        private void NotifyQuotasUpdated()
        {
            var app = System.Windows.Application.Current;
            if (app != null && app.Dispatcher != null)
            {
                app.Dispatcher.InvokeAsync(() => OnQuotasUpdated?.Invoke());
            }
            else
            {
                OnQuotasUpdated?.Invoke();
            }
        }

        public async Task RefreshAllAsync(RefreshTrigger trigger = RefreshTrigger.Manual)
        {
            // 原子地抢占闸门，避免定时器（线程池）与手动刷新（UI 线程）同时进入
            if (Interlocked.CompareExchange(ref _refreshing, 1, 0) != 0)
            {
                var startedTicks = Volatile.Read(ref _refreshStartedAtTicks);
                var elapsed = startedTicks == 0
                    ? TimeSpan.Zero
                    : TimeSpan.FromTicks(DateTime.UtcNow.Ticks - startedTicks);

                if (startedTicks != 0 && elapsed > GateStaleThreshold)
                {
                    // 上一轮卡死了。以前这里只是 return，于是每一次 tick 和每一次手动刷新
                    // 都被静默丢弃，界面上完全没有痕迹 —— 这正是"定时刷新彻底停摆"的成因。
                    // 闸门已经是 1，无需再 CAS，直接接管这一轮。
                    Log.Error("refresh", $"闸门被卡住 {elapsed.TotalSeconds:F1}s，强制抢占；trigger={trigger}");
                }
                else
                {
                    Log.Debug("refresh", $"跳过本次刷新：上一轮进行中 {elapsed.TotalSeconds:F1}s；trigger={trigger}");
                    return;
                }
            }

            Volatile.Write(ref _refreshStartedAtTicks, DateTime.UtcNow.Ticks);
            var myGeneration = Interlocked.Increment(ref _refreshGeneration);
            LastAttemptDate = DateTime.Now;
            var roundStart = System.Diagnostics.Stopwatch.StartNew();
            NotifyQuotasUpdated();

            Log.Notice("refresh", $"round begin trigger={trigger} providers={EnabledProviderNames()}");

            // 各刷新方法只在成功拿到数据时才推进自己的 LastUpdated，据此判断本轮是否有实际收获
            var updatedBefore = LatestQuotaUpdate();

            try
            {
                var tasks = new List<Task>();

                var gen = myGeneration;
                if (Settings.OpenAIEnabled) tasks.Add(RunProviderAsync("openai", ct => RefreshOpenAIAsync(ct, gen), ProviderType.OpenAI));
                if (Settings.ClaudeEnabled) tasks.Add(RunProviderAsync("claude", ct => RefreshClaudeAsync(ct, gen), ProviderType.ClaudeCode));
                if (Settings.GeminiEnabled) tasks.Add(RunProviderAsync("gemini", ct => RefreshGeminiAsync(ct, gen), ProviderType.Gemini));
                if (Settings.DeepSeekEnabled) tasks.Add(RunProviderAsync("deepseek", ct => RefreshDeepSeekAsync(ct, gen), ProviderType.DeepSeek));
                if (Settings.VolcengineEnabled) tasks.Add(RunProviderAsync("volcengine", ct => RefreshVolcengineAsync(ct, gen), ProviderType.Volcengine));
                if (Settings.KimiEnabled) tasks.Add(RunProviderAsync("kimi", ct => RefreshKimiAsync(ct, gen), ProviderType.Kimi));
                if (Settings.OpenRouterEnabled) tasks.Add(RunProviderAsync("openrouter", ct => RefreshOpenRouterAsync(ct, gen), ProviderType.OpenRouter));
                if (Settings.GLMEnabled) tasks.Add(RunProviderAsync("glm", ct => RefreshGLMAsync(ct, gen), ProviderType.GLM));
                if (Settings.AliyunEnabled) tasks.Add(RunProviderAsync("aliyun", ct => RefreshAliyunAsync(ct, gen), ProviderType.AliyunBailian));

                foreach (var config in Settings.CustomProviders.Where(c => c.IsEnabled))
                {
                    var captured = config;
                    tasks.Add(RunProviderAsync("custom", ct => RefreshCustomProviderAsync(captured, ct, gen), null, captured.Id));
                }

                await Task.WhenAll(tasks);

                // 全部厂商都失败时不推进时间戳，避免界面显示"刚刚更新"却是一屏旧数据
                var after = LatestQuotaUpdate();
                var advanced = after.HasValue && after != updatedBefore;
                if (advanced)
                {
                    LastRefreshDate = after;
                }
                LastRoundAdvanced = advanced;

                Log.Notice("refresh", $"round end in {roundStart.ElapsedMilliseconds}ms, advanced={advanced}");

                // 定时器自愈：定时器不存在、或生效中的间隔与设置不一致时，这里是最后一道防线
                // （与 mac RefreshTimerHealth.needsRebuild 同语义）。只判「定时器在不在」不够：
                // 任何漏掉 SaveSettings 的路径都会让新间隔永远不生效且界面毫无痕迹。
                if (_timer == null)
                {
                    Log.Error("timer", "定时器不存在，重建");
                    StartTimer();
                }
                else if (_activeIntervalMinutes != Settings.RefreshIntervalMinutes)
                {
                    Log.Error("timer",
                        $"定时器间隔与设置不符（生效 {_activeIntervalMinutes}min，设置 {Settings.RefreshIntervalMinutes}min），重建");
                    StartTimer();
                }
            }
            catch (Exception ex)
            {
                Log.Error("refresh", $"round 异常: {ex}");
            }
            finally
            {
                // 只有仍然是"当前那一轮"才收闸门；被抢占的旧轮次结束时什么都不做，
                // 否则会把接替它的新轮次的闸门提前打开。
                if (Volatile.Read(ref _refreshGeneration) == myGeneration)
                {
                    Volatile.Write(ref _refreshStartedAtTicks, 0);
                    Volatile.Write(ref _refreshing, 0);
                }
                NotifyQuotasUpdated();
            }
        }

        /// <summary>各厂商单轮的时间预算。百炼链路最长（AK 签发 + 网关 + 重试 + 余额），Gemini 次之。</summary>
        private static TimeSpan BudgetFor(string name) => name switch
        {
            "aliyun" => TimeSpan.FromSeconds(35),
            "gemini" => TimeSpan.FromSeconds(30),
            _ => TimeSpan.FromSeconds(25)
        };

        /// <summary>
        /// 给单个厂商的刷新套一层独立超时。
        ///
        /// 这是"一个厂商挂起就拖垮整轮刷新"的解药：Task.WhenAll 会等待全部任务，
        /// 以前任何一个厂商卡住都会让 RefreshAllAsync 迟迟不返回，闸门被占住，
        /// 之后每一次定时触发和手动刷新都被静默丢弃。
        ///
        /// 预算到期时通过 CancellationToken 真正取消底层 HTTP 请求（各服务把 ct 传到
        /// HttpClient.SendAsync），而不只是放弃等待；写回 ProviderQuota 前还按 generation 门控，
        /// 被抢占的旧轮次即使稍后返回也不会把新数据覆盖掉。
        /// </summary>
        private async Task RunProviderAsync(string name, Func<CancellationToken, Task> body, ProviderType? key, Guid? customId = null)
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            var budget = BudgetFor(name);
            using var cts = new CancellationTokenSource(budget);

            Task work;
            try
            {
                work = body(cts.Token);
            }
            catch (Exception ex)
            {
                // body 同步抛出（参数校验之类），不该让整轮挂掉
                Log.Error("provider", $"provider={name} 启动失败: {ex.Message}");
                return;
            }

            // 兜底等待：ct 取消后各服务应很快抛 OperationCanceledException 返回；
            // 子进程等不响应取消的路径再多给 5 秒，之后放弃等待（进程已由服务自行 Kill）。
            using var graceCts = new CancellationTokenSource();
            var grace = Task.Delay(budget + TimeSpan.FromSeconds(5), graceCts.Token);
            var winner = await Task.WhenAny(work, grace).ConfigureAwait(false);

            if (winner == work)
            {
                graceCts.Cancel();   // 回收 Task.Delay 的定时器，避免堆积
                try
                {
                    await work.ConfigureAwait(false);
                    Log.Info("provider", $"provider={name} done in {sw.ElapsedMilliseconds}ms");
                }
                catch (OperationCanceledException)
                {
                    Log.Error("provider", $"provider={name} TIMEOUT after {sw.ElapsedMilliseconds}ms（已取消）");
                    FinishTimedOutProvider(key, customId);
                }
                catch (Exception ex)
                {
                    Log.Error("provider", $"provider={name} failed: {ex.Message}");
                }
                return;
            }

            Log.Error("provider", $"provider={name} TIMEOUT after {sw.ElapsedMilliseconds}ms，取消后仍未返回，已放弃本轮");
            // 被放弃的厂商，其 IsLoading 会停在 true（卡片一直转圈），这里补一次收尾。
            FinishTimedOutProvider(key, customId);
        }

        /// <summary>
        /// 旧轮次的结果不能写回：generation 为 null 表示不是整轮刷新的一部分（设置页直接触发），
        /// 始终允许写回。
        /// </summary>
        private bool IsStaleGeneration(long? generation, string name)
        {
            if (!generation.HasValue) return false;
            if (Volatile.Read(ref _refreshGeneration) == generation.Value) return false;
            Log.Notice("provider", $"provider={name} 结果来自已被抢占的旧轮次，丢弃");
            return true;
        }

        private void FinishTimedOutProvider(ProviderType? key, Guid? customId)
        {
            var message = LocalizationManager.Instance.ErrRefreshTimeout;

            if (key.HasValue && Quotas.TryGetValue(key.Value, out var quota) && quota != null)
            {
                quota.IsLoading = false;
                quota.ErrorMessage = message;
            }
            else if (customId.HasValue && CustomQuotas.TryGetValue(customId.Value, out var custom) && custom != null)
            {
                custom.IsLoading = false;
                custom.ErrorMessage = message;
            }
        }

        /// <summary>本轮参与刷新的厂商名，只用于日志（都是固定标识，不含任何凭证）</summary>
        private string EnabledProviderNames()
        {
            var names = new List<string>();
            if (Settings.OpenAIEnabled) names.Add("openai");
            if (Settings.ClaudeEnabled) names.Add("claude");
            if (Settings.GeminiEnabled) names.Add("gemini");
            if (Settings.DeepSeekEnabled) names.Add("deepseek");
            if (Settings.VolcengineEnabled) names.Add("volcengine");
            if (Settings.KimiEnabled) names.Add("kimi");
            if (Settings.OpenRouterEnabled) names.Add("openrouter");
            if (Settings.GLMEnabled) names.Add("glm");
            if (Settings.AliyunEnabled) names.Add("aliyun");
            var customCount = Settings.CustomProviders.Count(c => c.IsEnabled);
            if (customCount > 0) names.Add($"custom x{customCount}");
            return string.Join(",", names);
        }

        /// <summary>所有厂商中最近一次成功更新的时间</summary>
        private DateTime? LatestQuotaUpdate()
        {
            DateTime? latest = null;
            foreach (var q in Quotas.Values)
            {
                if (q.LastUpdated is DateTime d && (latest is null || d > latest)) latest = d;
            }
            foreach (var q in CustomQuotas.Values)
            {
                if (q.LastUpdated is DateTime d && (latest is null || d > latest)) latest = d;
            }
            return latest;
        }

        public async Task RefreshOpenAIAsync(CancellationToken ct = default, long? generation = null)
        {
            var quota = Quotas[ProviderType.OpenAI];
            quota.IsLoading = true;
            quota.ErrorMessage = null;
            NotifyQuotasUpdated();

            if (string.IsNullOrWhiteSpace(Settings.OpenAIApiKey))
            {
                quota.IsAuthorized = false;
                quota.ErrorMessage = LocalizationManager.Instance.IsChinese ? "请在配置中输入 OpenAI API Key" : "Please configure OpenAI API Key";
                quota.IsLoading = false;
                NotifyQuotasUpdated();
                return;
            }

            try
            {
                var (primary, secondary, account) = await OpenAIService.Instance.FetchQuotaAsync(
                    Settings.OpenAIApiKey,
                    Settings.OpenAIEndpoint,
                    Settings.OpenAIOrgId,
                    ct);

                if (IsStaleGeneration(generation, "openai")) return;
                quota.FiveHourWindow = primary;
                quota.WeeklyWindow = secondary;
                quota.AccountInfo = account;
                quota.IsAuthorized = true;
                quota.LastUpdated = DateTime.Now;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                if (IsStaleGeneration(generation, "openai")) return;
                quota.IsAuthorized = false;
                quota.ErrorMessage = ex.Message;
                Log.Error("provider", $"provider=openai failed: {ex.Message}");
            }
            finally
            {
                quota.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        public async Task RefreshClaudeAsync(CancellationToken ct = default, long? generation = null)
        {
            var quota = Quotas[ProviderType.ClaudeCode];
            quota.IsLoading = true;
            quota.ErrorMessage = null;
            NotifyQuotasUpdated();

            bool hasClaudeToken = !string.IsNullOrWhiteSpace(Settings.ClaudeToken);
            var localClaude = ClaudeService.Instance.ReadLocalClaudeJson();
            bool hasAnthropicKey = !string.IsNullOrWhiteSpace(Settings.AnthropicApiKey);

            bool foundAuth = false;

            // 1. Claude Code token / local credentials
            if (hasClaudeToken)
            {
                try
                {
                    var (fiveHour, weekly, account) = await ClaudeService.Instance.FetchRemoteUsageAsync(Settings.ClaudeToken, ct);
                    if (IsStaleGeneration(generation, "claude")) return;
                    quota.FiveHourWindow = fiveHour;
                    quota.WeeklyWindow = weekly;
                    quota.IsAuthorized = true;
                    if (account != null) quota.AccountInfo = account;
                    foundAuth = true;
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                catch (Exception ex)
                {
                    Log.Warn("provider", $"claude 远程用量读取失败，退回本地缓存: {ex.Message}");
                    if (IsStaleGeneration(generation, "claude")) return;
                    if (localClaude != null)
                    {
                        quota.FiveHourWindow = localClaude.Value.FiveHour;
                        quota.WeeklyWindow = localClaude.Value.Weekly;
                        quota.IsAuthorized = true;
                        if (localClaude.Value.Account != null) quota.AccountInfo = localClaude.Value.Account;
                        foundAuth = true;
                    }
                }
            }
            else if (localClaude != null)
            {
                quota.FiveHourWindow = localClaude.Value.FiveHour;
                quota.WeeklyWindow = localClaude.Value.Weekly;
                quota.IsAuthorized = true;
                if (localClaude.Value.Account != null) quota.AccountInfo = localClaude.Value.Account;
                foundAuth = true;
            }

            // 2. Anthropic API Key
            if (hasAnthropicKey)
            {
                try
                {
                    var (primary, secondary, account) = await ClaudeService.Instance.FetchAnthropicQuotaAsync(
                        Settings.AnthropicApiKey,
                        Settings.AnthropicEndpoint,
                        ct);

                    if (IsStaleGeneration(generation, "claude")) return;
                    quota.FiveHourWindow ??= primary;
                    quota.WeeklyWindow ??= secondary;

                    if (account != null)
                    {
                        quota.AccountInfo = !string.IsNullOrEmpty(quota.AccountInfo)
                            ? $"{quota.AccountInfo} • {account}"
                            : account;
                    }
                    quota.IsAuthorized = true;
                    foundAuth = true;
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                catch (Exception ex)
                {
                    if (IsStaleGeneration(generation, "claude")) return;
                    if (!foundAuth)
                    {
                        quota.ErrorMessage = ex.Message;
                        Log.Error("provider", $"provider=claude failed: {ex.Message}");
                    }
                }
            }

            if (IsStaleGeneration(generation, "claude")) return;
            if (!foundAuth)
            {
                quota.IsAuthorized = false;
                quota.ErrorMessage ??= LocalizationManager.Instance.IsChinese ? "未配置 Anthropic API Key 或 Claude Code 网页/本地授权" : "Anthropic API Key or Claude Code authorization not configured";
            }

            // 与其他厂商对齐：只有真的拿到数据才算一次成功更新
            if (foundAuth)
            {
                quota.LastUpdated = DateTime.Now;
            }
            quota.IsLoading = false;
            NotifyQuotasUpdated();
        }

        public async Task RefreshGeminiAsync(CancellationToken ct = default, long? generation = null)
        {
            var quota = Quotas[ProviderType.Gemini];
            quota.IsLoading = true;
            quota.ErrorMessage = null;
            NotifyQuotasUpdated();

            bool hasApiKey = !string.IsNullOrWhiteSpace(Settings.GeminiApiKey);

            // 1. Prioritize Google AI Studio API Key if configured
            if (hasApiKey)
            {
                try
                {
                    var (fiveHour, weekly, account) = await GeminiService.Instance.FetchQuotaWithApiKeyAsync(
                        Settings.GeminiApiKey,
                        Settings.GeminiEndpoint,
                        ct);

                    if (IsStaleGeneration(generation, "gemini")) return;
                    quota.FiveHourWindow = fiveHour;
                    quota.WeeklyWindow = weekly;
                    quota.IsAuthorized = true;
                    quota.AccountInfo = account;
                    quota.LastUpdated = DateTime.Now;
                    quota.IsLoading = false;
                    NotifyQuotasUpdated();
                    return;
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                catch (Exception ex)
                {
                    var local = GeminiService.Instance.ReadLocalGeminiConfig();
                    bool hasOAuth = !string.IsNullOrWhiteSpace(Settings.GeminiToken) || local.Account != null || local.Token != null;
                    if (!hasOAuth)
                    {
                        if (IsStaleGeneration(generation, "gemini")) return;
                        quota.IsAuthorized = false;
                        quota.ErrorMessage = ex.Message;
                        Log.Error("provider", $"provider=gemini failed: {ex.Message}");
                        quota.IsLoading = false;
                        NotifyQuotasUpdated();
                        return;
                    }
                }
            }

            // 2. OAuth Web Login / Local Credentials Fallback
            try
            {
                var (fiveHour, weekly, account) = await GeminiService.Instance.FetchQuotaAsync(Settings.GeminiToken, ct);
                if (IsStaleGeneration(generation, "gemini")) return;
                quota.FiveHourWindow = fiveHour;
                quota.WeeklyWindow = weekly;
                quota.IsAuthorized = true;
                if (account != null) quota.AccountInfo = account;
                quota.LastUpdated = DateTime.Now;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                if (IsStaleGeneration(generation, "gemini")) return;
                quota.IsAuthorized = false;
                quota.ErrorMessage = ex.Message;
                Log.Error("provider", $"provider=gemini failed: {ex.Message}");
            }
            finally
            {
                quota.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        public async Task RefreshDeepSeekAsync(CancellationToken ct = default, long? generation = null)
        {
            var quota = Quotas[ProviderType.DeepSeek];
            quota.IsLoading = true;
            quota.ErrorMessage = null;
            NotifyQuotasUpdated();

            if (string.IsNullOrWhiteSpace(Settings.DeepSeekApiKey))
            {
                quota.IsAuthorized = false;
                quota.ErrorMessage = LocalizationManager.Instance.IsChinese ? "请在配置中输入 DeepSeek API Key" : "Please configure DeepSeek API Key";
                quota.IsLoading = false;
                NotifyQuotasUpdated();
                return;
            }

            try
            {
                var (primary, secondary, account) = await DeepSeekService.Instance.FetchQuotaAsync(
                    Settings.DeepSeekApiKey,
                    Settings.DeepSeekEndpoint,
                    Settings.DeepSeekModel,
                    Settings.DeepSeekBalanceAlertThreshold,
                    ct);

                if (IsStaleGeneration(generation, "deepseek")) return;

                quota.FiveHourWindow = primary;
                quota.WeeklyWindow = secondary;
                quota.AccountInfo = account;
                quota.IsAuthorized = true;
                quota.LastUpdated = DateTime.Now;

                ProcessBalance("deepseek", ProviderType.DeepSeek.GetDisplayName(),
                    quota.WeeklyWindow, Settings.DeepSeekBalanceAlertThreshold);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                if (IsStaleGeneration(generation, "deepseek")) return;
                quota.IsAuthorized = false;
                quota.ErrorMessage = ex.Message;
                Log.Error("provider", $"provider=deepseek failed: {ex.Message}");
            }
            finally
            {
                quota.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        public async Task RefreshVolcengineAsync(CancellationToken ct = default, long? generation = null)
        {
            var quota = Quotas[ProviderType.Volcengine];
            quota.IsLoading = true;
            quota.ErrorMessage = null;
            NotifyQuotasUpdated();

            if (string.IsNullOrWhiteSpace(Settings.VolcengineApiKey))
            {
                quota.IsAuthorized = false;
                quota.ErrorMessage = LocalizationManager.Instance.IsChinese ? "请在配置中输入火山方舟 API Key" : "Please configure Volcengine Ark API Key";
                quota.IsLoading = false;
                NotifyQuotasUpdated();
                return;
            }

            try
            {
                var (primary, secondary, account) = await VolcengineService.Instance.FetchQuotaAsync(
                    Settings.VolcengineApiKey,
                    Settings.VolcengineEndpoint,
                    Settings.VolcengineModel,
                    ct);

                if (IsStaleGeneration(generation, "volcengine")) return;

                quota.FiveHourWindow = primary;
                quota.WeeklyWindow = secondary;
                quota.AccountInfo = account;
                quota.IsAuthorized = true;
                quota.LastUpdated = DateTime.Now;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                if (IsStaleGeneration(generation, "volcengine")) return;
                quota.IsAuthorized = false;
                quota.ErrorMessage = ex.Message;
                Log.Error("provider", $"provider=volcengine failed: {ex.Message}");
            }
            finally
            {
                quota.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        public async Task RefreshKimiAsync(CancellationToken ct = default, long? generation = null)
        {
            var quota = Quotas[ProviderType.Kimi];
            quota.IsLoading = true;
            quota.ErrorMessage = null;
            NotifyQuotasUpdated();

            if (string.IsNullOrWhiteSpace(Settings.KimiApiKey))
            {
                quota.IsAuthorized = false;
                quota.ErrorMessage = LocalizationManager.Instance.IsChinese ? "请在配置中输入 KIMI API Key" : "Please configure KIMI API Key";
                quota.IsLoading = false;
                NotifyQuotasUpdated();
                return;
            }

            try
            {
                var (primary, secondary, account) = await KimiService.Instance.FetchQuotaAsync(
                    Settings.KimiApiKey,
                    Settings.KimiEndpoint,
                    Settings.KimiModel,
                    Settings.KimiBalanceAlertThreshold,
                    ct);

                if (IsStaleGeneration(generation, "kimi")) return;

                quota.FiveHourWindow = primary;
                quota.WeeklyWindow = secondary;
                quota.AccountInfo = account;
                quota.IsAuthorized = true;
                quota.LastUpdated = DateTime.Now;

                ProcessBalance("kimi", ProviderType.Kimi.GetDisplayName(),
                    quota.WeeklyWindow, Settings.KimiBalanceAlertThreshold);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                if (IsStaleGeneration(generation, "kimi")) return;
                quota.IsAuthorized = false;
                quota.ErrorMessage = ex.Message;
                Log.Error("provider", $"provider=kimi failed: {ex.Message}");
            }
            finally
            {
                quota.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        public async Task RefreshOpenRouterAsync(CancellationToken ct = default, long? generation = null)
        {
            var quota = Quotas[ProviderType.OpenRouter];
            quota.IsLoading = true;
            quota.ErrorMessage = null;
            NotifyQuotasUpdated();

            if (string.IsNullOrWhiteSpace(Settings.OpenRouterApiKey))
            {
                quota.IsAuthorized = false;
                quota.ErrorMessage = LocalizationManager.Instance.IsChinese ? "请在配置中输入 OpenRouter API Key" : "Please configure OpenRouter API Key";
                quota.IsLoading = false;
                NotifyQuotasUpdated();
                return;
            }

            try
            {
                var (primary, secondary, account) = await OpenRouterService.Instance.FetchQuotaAsync(
                    Settings.OpenRouterApiKey,
                    Settings.OpenRouterEndpoint,
                    Settings.OpenRouterBalanceAlertThreshold,
                    ct);

                if (IsStaleGeneration(generation, "openrouter")) return;

                quota.FiveHourWindow = primary;
                quota.WeeklyWindow = secondary;
                quota.AccountInfo = account;
                quota.IsAuthorized = true;
                quota.LastUpdated = DateTime.Now;

                ProcessBalance("openrouter", ProviderType.OpenRouter.GetDisplayName(),
                    quota.FiveHourWindow, Settings.OpenRouterBalanceAlertThreshold);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                if (IsStaleGeneration(generation, "openrouter")) return;
                quota.IsAuthorized = false;
                quota.ErrorMessage = ex.Message;
                Log.Error("provider", $"provider=openrouter failed: {ex.Message}");
            }
            finally
            {
                quota.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        public async Task RefreshGLMAsync(CancellationToken ct = default, long? generation = null)
        {
            var quota = Quotas[ProviderType.GLM];
            quota.IsLoading = true;
            quota.ErrorMessage = null;
            NotifyQuotasUpdated();

            if (string.IsNullOrWhiteSpace(Settings.GLMApiKey))
            {
                quota.IsAuthorized = false;
                quota.ErrorMessage = LocalizationManager.Instance.IsChinese ? "请在配置中输入 GLM API KEY" : "Please configure GLM API Key";
                quota.IsLoading = false;
                NotifyQuotasUpdated();
                return;
            }

            try
            {
                var (fiveHour, weekly, account) = await GLMService.Instance.FetchQuotaAsync(
                    Settings.GLMApiKey,
                    Settings.GLMEndpoint,
                    ct);

                if (IsStaleGeneration(generation, "glm")) return;

                quota.FiveHourWindow = fiveHour;
                quota.WeeklyWindow = weekly;
                quota.AccountInfo = account;
                quota.IsAuthorized = true;
                quota.LastUpdated = DateTime.Now;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                if (IsStaleGeneration(generation, "glm")) return;
                quota.IsAuthorized = false;
                quota.ErrorMessage = ex.Message;
                Log.Error("provider", $"provider=glm failed: {ex.Message}");
            }
            finally
            {
                quota.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        public async Task RefreshAliyunAsync(CancellationToken ct = default, long? generation = null)
        {
            var quota = Quotas[ProviderType.AliyunBailian];
            quota.IsLoading = true;
            quota.ErrorMessage = null;
            NotifyQuotasUpdated();

            try
            {
                // 凭据在后台线程读。同步的 Cred* P/Invoke 卡住时会占满这个 provider
                // 的时间预算，与 mac 端 KeychainSecretStore.prefetch 的用意一致。
                var prefetched = await CredentialSecretStore.Instance.PrefetchAsync(
                    SecretKey.AliyunAccessKeySecret, SecretKey.AliyunConsoleAccessToken);
                var credentials = AliyunBailianService.ResolveCredentials(Settings, prefetched);
                var res = await AliyunBailianService.Instance.FetchQuotaAsync(credentials, ct);

                if (IsStaleGeneration(generation, "aliyun")) return;

                // 新签发的控制台令牌落进凭据管理器，下次刷新直接复用，避免重复签发。
                // 写入不阻塞刷新，交给后台。
                if (!string.IsNullOrEmpty(res.RefreshedToken))
                {
                    CredentialSecretStore.Instance.SetInBackground(
                        SecretKey.AliyunConsoleAccessToken, res.RefreshedToken!);
                }

                quota.FiveHourWindow = res.FiveHour;
                quota.WeeklyWindow = res.Weekly;
                quota.AccountInfo = res.Account;
                quota.IsAuthorized = true;
                // 网关成功但没返回窗口数据时，用 Note 说明「可能不限量」，
                // 而不是让卡片停在「同步中」——但仍算已授权，不是失败态
                quota.ErrorMessage = res.Note;
                quota.LastUpdated = DateTime.Now;

                // 账户现金余额与额度相互独立：需要 AK/SK 且额外的 bss:DescribeAcccount 权限，
                // 查不到时静默跳过，不能连累已经拿到的额度数据
                quota.BalanceWindow = null;
                if (credentials.HasAccessKey)
                {
                    try
                    {
                        var balance = await AliyunBailianService.Instance
                            .FetchAccountBalanceAsync(credentials, ct);
                        if (IsStaleGeneration(generation, "aliyun")) return;
                        quota.BalanceWindow = new TokenWindow
                        {
                            Title = "账户余额",
                            Kind = TokenWindowKind.Balance,
                            BalanceAmount = (decimal)balance.Amount,
                            Currency = balance.Currency,
                            WarningThreshold = Settings.AliyunBalanceAlertThreshold,
                            CriticalThreshold = Settings.AliyunBalanceAlertThreshold / 2,
                            StartTime = DateTime.Now,
                            EndTime = DateTime.Now.AddDays(30)
                        };
                        ProcessBalance("aliyun", ProviderType.AliyunBailian.GetDisplayName(),
                            quota.BalanceWindow, Settings.AliyunBalanceAlertThreshold);
                    }
                    catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                    catch (Exception ex)
                    {
                        // 余额是附加信息：查不到只记日志，不能连累已经拿到的额度数据
                        Log.Warn("provider", $"aliyun 账户余额查询失败: {ex.Message}");
                    }
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                if (IsStaleGeneration(generation, "aliyun")) return;
                quota.IsAuthorized = false;
                quota.ErrorMessage = ex.Message;
                Log.Error("provider", $"provider=aliyun failed: {ex.Message}");
            }
            finally
            {
                quota.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        public async Task RefreshCustomProviderAsync(CustomProviderConfig config, CancellationToken ct = default, long? generation = null)
        {
            var q = CustomQuotas.GetOrAdd(config.Id, _ => new CustomProviderQuota
            {
                ConfigId = config.Id,
                Name = config.Name,
                Protocol = config.Protocol
            });

            q.IsLoading = true;
            q.ErrorMessage = null;
            NotifyQuotasUpdated();

            if (string.IsNullOrWhiteSpace(config.ApiKey))
            {
                q.IsAuthorized = false;
                q.ErrorMessage = LocalizationManager.Instance.IsChinese ? "请在配置中填入 API KEY" : "Please configure API Key";
                q.IsLoading = false;
                NotifyQuotasUpdated();
                return;
            }

            try
            {
                var (primary, secondary, account) = await CustomProviderService.Instance.FetchQuotaAsync(config, ct);
                if (IsStaleGeneration(generation, "custom")) return;
                q.PrimaryWindow = primary;
                q.SecondaryWindow = secondary;
                q.AccountInfo = account;
                q.IsAuthorized = true;
                q.LastUpdated = DateTime.Now;

                // 余额窗口可能在主槽位（纯余额厂商）或副槽位（MiMo 等订阅+余额双通道厂商）
                var balanceWin = primary?.Kind == TokenWindowKind.Balance ? primary
                    : secondary?.Kind == TokenWindowKind.Balance ? secondary
                    : null;
                ProcessBalance($"custom:{config.Id}", config.Name,
                    balanceWin, config.BalanceAlertThreshold ?? 10);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                if (IsStaleGeneration(generation, "custom")) return;
                q.IsAuthorized = false;
                q.ErrorMessage = ex.Message;
                Log.Error("provider", $"provider=custom failed: {ex.Message}");
            }
            finally
            {
                q.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        /// <summary>
        /// 余额窗口刷新成功后的统一处理：
        /// 1) 记录与上次刷新的差值（内存）；2) 写入本地历史并计算"预计可用天数"；
        /// 3) 低余额时触发一次托盘气泡提醒，恢复到阈值 1.2 倍以上后重新武装。
        /// </summary>
        private void ProcessBalance(string providerKey, string displayName, TokenWindow? window, decimal threshold)
        {
            if (window == null || window.Kind != TokenWindowKind.Balance || !window.BalanceAmount.HasValue) return;
            var amount = window.BalanceAmount.Value;

            lock (_balanceLock)
            {
                if (_lastBalance.TryGetValue(providerKey, out var prev))
                {
                    window.LastDelta = amount - prev;
                }
                _lastBalance[providerKey] = amount;
            }

            BalanceHistoryStore.Record(providerKey, amount);
            window.ForecastDays = BalanceHistoryStore.GetForecastDays(providerKey, amount);

            if (threshold <= 0) return;

            bool fire = false;
            lock (_balanceLock)
            {
                if (amount < threshold)
                {
                    fire = _balanceAlerted.Add(providerKey);
                }
                else if (amount >= threshold * 1.2m)
                {
                    _balanceAlerted.Remove(providerKey);
                }
            }

            if (fire)
            {
                var i18n = LocalizationManager.Instance;
                var title = i18n.LowBalanceTitle;
                var body = string.Format(i18n.LowBalanceBody, displayName, window.BalanceFormatted);
                var app = System.Windows.Application.Current;
                if (app != null && app.Dispatcher != null)
                {
                    app.Dispatcher.InvokeAsync(() => TrayIconManager.Instance?.ShowBalloon(title, body));
                }
                else
                {
                    TrayIconManager.Instance?.ShowBalloon(title, body);
                }
            }
        }

        public bool ImportClaudeFromLocal()
        {
            var local = ClaudeService.Instance.ReadLocalClaudeJson();
            if (local != null)
            {
                var quota = Quotas[ProviderType.ClaudeCode];
                quota.IsAuthorized = true;
                quota.AccountInfo = local.Value.Account;
                quota.FiveHourWindow = local.Value.FiveHour;
                quota.WeeklyWindow = local.Value.Weekly;
                quota.LastUpdated = DateTime.Now;
                NotifyQuotasUpdated();
                return true;
            }
            return false;
        }

        public bool ImportGeminiFromLocal()
        {
            var local = GeminiService.Instance.ReadLocalGeminiConfig();
            if (local.Token != null)
            {
                Settings.GeminiToken = local.Token;
                SaveSettings();
                _ = RefreshGeminiAsync();
                return true;
            }
            return false;
        }

        public void AddCustomProvider(CustomProviderConfig config)
        {
            Settings.CustomProviders.Add(config);
            CustomQuotas[config.Id] = new CustomProviderQuota
            {
                ConfigId = config.Id,
                Name = config.Name,
                Protocol = config.Protocol
            };
            SaveSettings();
            _ = RefreshCustomProviderAsync(config);
        }

        public void UpdateCustomProvider(CustomProviderConfig config)
        {
            var idx = Settings.CustomProviders.FindIndex(c => c.Id == config.Id);
            if (idx >= 0)
            {
                Settings.CustomProviders[idx] = config;
                SaveSettings();
                _ = RefreshCustomProviderAsync(config);
            }
        }

        public void RemoveCustomProvider(Guid id)
        {
            Settings.CustomProviders.RemoveAll(c => c.Id == id);
            CustomQuotas.TryRemove(id, out _);
            lock (_balanceLock)
            {
                _lastBalance.Remove($"custom:{id}");
                _balanceAlerted.Remove($"custom:{id}");
            }
            BalanceHistoryStore.Clear($"custom:{id}");
            // 该厂商的两个凭据条目由 SaveSettings 的差异同步删除：它们从 Extract 结果里消失、
            // 但仍在 _persistedSecrets 中，ResolveSave 会判成 Delete。不要在这里另开一条删除路径 ——
            // 那会在线程池上与 SyncSecretsToStoreAsync 并发改同一个字典。
            SaveSettings();
            NotifyQuotasUpdated();
        }

        /// <summary>
        /// 应用浮动框卡片显示顺序（ProviderOrdering 键），保存设置并通知浮动框立即重渲染。
        /// </summary>
        public void ApplyProviderOrder(List<string> order)
        {
            Settings.ProviderOrder = order;
            SaveSettings();
            NotifyQuotasUpdated();
        }

        public void Dispose()
        {
            _secretSyncGate.Dispose();
            _timer?.Dispose();
        }
    }
}
