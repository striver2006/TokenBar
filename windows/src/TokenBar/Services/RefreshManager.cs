using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Net.NetworkInformation;
using System.Threading;
using System.Threading.Tasks;
using Timer = System.Threading.Timer;
using TokenBar.I18n;
using TokenBar.Models;

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
        public bool IsRefreshing => _gate.IsBusy;
        public DateTime? LastRefreshDate { get; private set; }

        // 全量刷新互斥闸门 + 轮次代数（CAS 抢占、卡死接管、generation 防脏写）。
        // 机制细节与单测见 RefreshGate。
        private readonly RefreshGate _gate = new();

        // 上一次定时器触发的时刻，用于在日志里暴露真实间隔
        private DateTime? _lastTimerFire;

        /// <summary>最近一次"发起过刷新"的时刻，无论成败都推进。</summary>
        public DateTime? LastAttemptDate { get; private set; }
        /// <summary>最近一轮是否拿到了新数据，用于让"刷新了但全失败"对用户可见。</summary>
        public bool LastRoundAdvanced { get; private set; }

        // 连续「全失败轮次」计数（LastRoundAdvanced == false），任一轮 advanced 即清零。
        // 只被定时器退避消费：稳态下全失败时按 2^n（上限 8 倍）指数拉长实际请求间隔，
        // 手动 / 唤醒 / 设置刷新不受影响。与 mac 端 failureBackoff 同语义。
        private int _consecutiveFailedRounds;

        private Timer? _timer;
        // 当前定时器生效的间隔，用于判断设置变更是否真的需要重建定时器
        private int? _activeIntervalMinutes;

        // settings.json 的加载与原子写（路径、损坏保留、临时文件替换都在里面）
        private readonly SettingsStore _settingsStore = new();

        // 余额窗口的展示辅助状态（较上次差值 + 低余额提醒状态机）+ 托盘气泡
        private readonly BalanceMonitor _balanceMonitor = new();

        public event Action? OnQuotasUpdated;

        // ---------- 凭证托管状态（与 mac 端 RefreshManager 的 persistedSecrets / unreadableSecretKeys 同构） ----------

        // 凭据管理器的加载/迁移/差异同步编排；P/Invoke 在 CredentialSecretStore，状态在 SecretSync
        private readonly SecretSync _secretSync;

        /// <summary>凭据管理器当前的错误态；null 表示正常。设置窗口据此显示橙色横幅。</summary>
        public SecretStoreErrorKind? SecretStoreErrorState => _secretSync.ErrorState;

        /// <summary>SecretStoreErrorState 对应的本地化文案（随当前语言变化），null 表示没有错误</summary>
        public string? SecretStoreError => SecretStoreErrorState switch
        {
            SecretStoreErrorKind.Unavailable => LocalizationManager.Instance.WarnSecretStoreUnavailable,
            SecretStoreErrorKind.WriteFailed => LocalizationManager.Instance.WarnSecretStoreWriteFailed,
            _ => null
        };

        /// <summary>SecretStoreErrorState 变化时在 UI 线程触发</summary>
        public event Action? OnSecretStoreErrorChanged
        {
            add => _secretSync.ErrorChanged += value;
            remove => _secretSync.ErrorChanged -= value;
        }

        private RefreshManager()
        {
            // Settings 会被 LoadSettings 整体替换，SecretSync 通过访问器现取；
            // 重写 settings.json 走 PersistSettingsToDisk 回调（内部是 SettingsStore.Save）
            _secretSync = new SecretSync(() => Settings, PersistSettingsToDisk);
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
            HookNetworkRecovery();
            Log.Notice("lifecycle", $"TokenBar 启动，refreshInterval={Settings.RefreshIntervalMinutes}min");
            LoadSecretsThenInitialRefreshAsync().FireAndForget("initial-refresh");
        }

        // 首刷全轮失败后的退避重试间隔。开机自启动时网络常未就绪，只等定时器要一个完整
        // 间隔（默认 5 分钟）；两次短退避把「过一阵才恢复」缩短到半分钟内。
        private static readonly int[] InitialRetryDelaysSeconds = { 15, 45 };

        // NetworkAvailabilityChanged 是否已订阅，Dispose 时据此取消
        private bool _networkHooked;

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

            // 首刷因刷新失败（网络未就绪等）没拿到数据时退避重试；全是「未配置」则没有重试意义
            foreach (var delay in InitialRetryDelaysSeconds)
            {
                if (!AnyRefreshError()) return;
                await Task.Delay(TimeSpan.FromSeconds(delay)).ConfigureAwait(false);
                if (!AnyRefreshError()) return;   // 等待期间定时器/手动/网络恢复补刷已成功
                Log.Notice("refresh", $"首刷未拿到数据，{delay}s 后重试");
                await RefreshAllAsync(RefreshTrigger.Initial).ConfigureAwait(false);
            }
        }

        /// <summary>是否有厂商处于「刷新失败」态（区别于「未配置」）</summary>
        private bool AnyRefreshError() =>
            Quotas.Values.Any(q => q.HadRefreshError) || CustomQuotas.Values.Any(q => q.HadRefreshError);

        /// <summary>
        /// 网络恢复补刷：开机时网络未就绪导致首刷全败后，网络一通立即补刷，不等退避重试或定时器。
        /// 事件在线程池触发；RefreshIfStaleAsync 自带 60 秒去抖，RefreshAllAsync 自带闸门，重复事件无害。
        /// </summary>
        private void HookNetworkRecovery()
        {
            try
            {
                NetworkChange.NetworkAvailabilityChanged += OnNetworkAvailabilityChanged;
                _networkHooked = true;
            }
            catch (Exception ex)
            {
                // 个别精简系统没有 NetworkInformation 服务，注册失败不影响其余流程
                Log.Error("lifecycle", $"注册网络状态监听失败: {ex.Message}");
            }
        }

        private async void OnNetworkAvailabilityChanged(object? sender, NetworkAvailabilityEventArgs e)
        {
            if (!e.IsAvailable) return;
            try
            {
                Log.Notice("lifecycle", "网络已恢复，触发补刷");
                await RefreshIfStaleAsync(TimeSpan.FromMinutes(2));
            }
            catch (Exception ex)
            {
                Log.Error("lifecycle", $"网络恢复补刷异常: {ex.Message}");
            }
        }

        // MARK: - 凭证与凭据管理器（加载/迁移/差异同步的编排在 SecretSync，这里只做转发）

        /// <summary>
        /// 启动时把全部凭证从凭据管理器读进 Settings，并把 settings.json 里的旧明文一次性迁进凭据管理器。
        /// 三态处理（Found / Migrate / KeepLegacy）与「绝不丢用户凭证」的兜底语义见 SecretSync.LoadFromStoreAsync。
        /// </summary>
        public Task LoadSecretsFromStoreAsync() => _secretSync.LoadFromStoreAsync();

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
                q.ScopedWeeklyWindow = localClaude.Value.ScopedWeekly;
                q.IsFromLocalCache = true;
                q.LocalCacheFetchedAt = localClaude.Value.FetchedAt;
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
            // 文件缺失/反序列化出 null 时 Load 原样返回当前 Settings（引用不变），
            // 读取异常时返回全新 AppSettings 并把损坏文件改名保留 —— 与原实现逐字等价
            Settings = _settingsStore.Load(Settings);

            LocalizationManager.Instance.CurrentLanguage = Settings.Language;
        }

        /// <summary>只写 settings.json（凭证字段是否落盘由 Settings.SecretsInKeychain 决定），不碰凭据管理器</summary>
        private void PersistSettingsToDisk() => _settingsStore.Save(Settings);

        public void SaveSettings()
        {
            PersistSettingsToDisk();
            // 凭证差异写入凭据管理器在后台进行；失败会置 SecretStoreErrorState 并把明文重写回 settings.json 兜底。
            // 快照在这里（调用线程）取，后台任务只用这份不可变副本。
            _secretSync.SyncToStoreAsync(AppSecrets.Extract(Settings)).FireAndForget("secret-sync");

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

        private readonly object _timerLock = new();

        public void StartTimer()
        {
            // UI 线程（SaveSettings）与线程池（RefreshAllAsync finally 的定时器自愈）
            // 可能并发进入；Dispose+new 非原子会泄漏一个永不释放、按旧间隔继续 tick 的 Timer。
            lock (_timerLock)
            {
                _timer?.Dispose();
                var interval = Math.Max(1, Settings.RefreshIntervalMinutes);
                _timer = new Timer(TimerTickAsync, null, TimeSpan.FromMinutes(interval), TimeSpan.FromMinutes(interval));
                _activeIntervalMinutes = Settings.RefreshIntervalMinutes;
                _lastTimerFire = null;
                Log.Notice("timer", $"定时器已创建：interval={interval}min");
            }
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

                // 稳态失败退避（#20，与 mac 端 failureBackoff 同一语义）：连续全失败 n 轮后，
                // tick 到点但距上次尝试不足 baseInterval × min(2^n, 8) 时跳过本轮，
                // 网络持续故障时不再按固定间隔硬打所有厂商。只拦定时器轮次——
                // 手动 / 唤醒 / 设置变更刷新直接走 RefreshAllAsync，不经过这里。
                var baseInterval = TimeSpan.FromMinutes(Math.Max(1, Settings.RefreshIntervalMinutes));
                if (LastAttemptDate is DateTime lastAttempt &&
                    ShouldSkipTimerRefresh(_consecutiveFailedRounds, baseInterval, DateTime.Now - lastAttempt))
                {
                    Log.Info("timer",
                        $"失败退避：连续 {_consecutiveFailedRounds} 轮全失败，距上次尝试 {(DateTime.Now - lastAttempt).TotalSeconds:F0}s 未到退避后的间隔，跳过本轮 tick");
                    return;
                }

                await RefreshAllAsync(RefreshTrigger.Timer);
            }
            catch (Exception ex)
            {
                Log.Error("timer", $"定时刷新回调异常: {ex}");
            }
        }

        /// <summary>退避倍率：2^n，封顶 8 倍（= 1 &lt;&lt; 3），移位前先钳住 n 防溢出。</summary>
        private static int BackoffFactor(int consecutiveFailures) =>
            1 << Math.Min(Math.Max(consecutiveFailures, 0), 3);

        /// <summary>
        /// 稳态失败退避的纯判定（与 mac 端 RefreshManager.failureBackoff 同形同语义）：
        /// 连续全失败 n &gt; 0 轮、且距上次尝试不足 baseInterval × min(2^n, 8) 时应跳过本轮定时刷新。
        /// n == 0（上一轮有收获）或已达退避间隔则不跳过。
        /// </summary>
        internal static bool ShouldSkipTimerRefresh(int consecutiveFailures, TimeSpan baseInterval, TimeSpan elapsedSinceLastAttempt)
        {
            if (consecutiveFailures <= 0) return false;
            var backoff = TimeSpan.FromTicks(baseInterval.Ticks * BackoffFactor(consecutiveFailures));
            return elapsedSinceLastAttempt < backoff;
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
            var (acquire, myGeneration, heldFor) = _gate.TryBegin();
            if (acquire == GateAcquireResult.Skipped)
            {
                Log.Debug("refresh", $"跳过本次刷新：上一轮进行中 {heldFor.TotalSeconds:F1}s；trigger={trigger}");
                return;
            }
            if (acquire == GateAcquireResult.TookOverStale)
            {
                // 上一轮卡死了。以前这里只是 return，于是每一次 tick 和每一次手动刷新
                // 都被静默丢弃，界面上完全没有痕迹 —— 这正是"定时刷新彻底停摆"的成因。
                Log.Error("refresh", $"闸门被卡住 {heldFor.TotalSeconds:F1}s，强制抢占；trigger={trigger}");
            }

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
                    _consecutiveFailedRounds = 0;
                }
                else if (tasks.Count > 0)
                {
                    // 稳态失败退避计数（#20，与 mac 同一语义）：任一轮拿到新数据即清零；
                    // 全失败且有厂商实际参与才累加（零厂商参与时没有发出任何请求，不该推高计数）
                    _consecutiveFailedRounds++;
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
                _gate.End(myGeneration);
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

        // 单厂商互斥锁。设置页「测试连接」直调 RefreshXxxAsync（绕过整轮闸门），
        // 与定时轮次可能并发写同一 ProviderQuota——它是无锁普通字段类，会产生
        // 数据竞争且状态互相覆盖（如测试成功清掉轮次刚写的超时错误）。
        // 每个厂商一把锁，把所有入口（轮次 / 托盘手动 / 设置页测试）串行化。
        private readonly ConcurrentDictionary<string, SemaphoreSlim> _providerLocks = new();

        private async Task WithProviderLockAsync(string name, CancellationToken ct, Func<Task> body)
        {
            var sem = _providerLocks.GetOrAdd(name, static _ => new SemaphoreSlim(1, 1));
            await sem.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                await body().ConfigureAwait(false);
            }
            finally
            {
                sem.Release();
            }
        }

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
            var result = await ProviderBudgetRunner.RunAsync(body, budget, TimeSpan.FromSeconds(5));

            switch (result.Outcome)
            {
                case ProviderRunOutcome.Completed:
                    Log.Info("provider", $"provider={name} done in {sw.ElapsedMilliseconds}ms");
                    break;
                case ProviderRunOutcome.StartFailed:
                    // body 同步抛出（参数校验之类），不该让整轮挂掉
                    Log.Error("provider", $"provider={name} 启动失败: {result.Error?.Message}");
                    break;
                case ProviderRunOutcome.TimedOut:
                    Log.Error("provider", $"provider={name} TIMEOUT after {sw.ElapsedMilliseconds}ms（已取消）");
                    FinishTimedOutProvider(key, customId);
                    break;
                case ProviderRunOutcome.Faulted:
                    Log.Error("provider", $"provider={name} failed: {result.Error?.Message}");
                    break;
                case ProviderRunOutcome.Abandoned:
                    Log.Error("provider", $"provider={name} TIMEOUT after {sw.ElapsedMilliseconds}ms，取消后仍未返回，已放弃本轮");
                    // 被放弃的厂商，其 IsLoading 会停在 true（卡片一直转圈），这里补一次收尾。
                    FinishTimedOutProvider(key, customId);
                    break;
            }
        }

        /// <summary>
        /// 旧轮次的结果不能写回：generation 为 null 表示不是整轮刷新的一部分（设置页直接触发），
        /// 始终允许写回。
        /// </summary>
        private bool IsStaleGeneration(long? generation, string name)
        {
            if (!_gate.IsStaleGeneration(generation)) return false;
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
                // 超时大多是网络未就绪/服务端无响应，不算「未配置」；授权态与旧数据保留
                quota.HadRefreshError = true;
            }
            else if (customId.HasValue && CustomQuotas.TryGetValue(customId.Value, out var custom) && custom != null)
            {
                custom.IsLoading = false;
                custom.ErrorMessage = message;
                custom.HadRefreshError = true;
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

        // ---------- 六个简单厂商的表驱动 ----------
        //
        // OpenAI / DeepSeek / Volcengine / Kimi / OpenRouter / GLM 六份 Core 的骨架逐字相同：
        // 置 IsLoading → 空 Key 检查 → Fetch → IsStaleGeneration → 写回 6 个字段（FiveHourWindow/
        // WeeklyWindow/AccountInfo/IsAuthorized/HadRefreshError/LastUpdated）→ catch 记 HadRefreshError
        // → finally 收尾 Notify。差异只有四点，全部收进 SimpleProviderSpec：
        //   1) settings 的 Key 字段（ApiKey）；
        //   2) 空 Key 文案（MissingKeyZh/En；GLM 中文是大写 "KEY"、英文是 "Key"，逐字保留）；
        //   3) 服务调用签名（Fetch：参数个数/顺序不同，有的带 model / balanceAlertThreshold；
        //      返回槽位名 (FiveHour,Weekly) 与 (Primary,Secondary) 只是元命名差异，写回目标字段相同）；
        //   4) 成功写回后的余额提醒（AfterSuccess：DeepSeek/Kimi 用 WeeklyWindow，OpenRouter 用
        //      FiveHourWindow，其余三家没有）。
        // 错误分类（HadRefreshError=true + ErrorMessage=ex.Message + Log.Error）与 IsAuthorized 语义
        // （空 Key → false；成功 → true；失败保留原状）六家完全一致，留在执行器里。
        // Claude / Gemini / AliyunBailian / CustomProvider 有多授权通道、令牌刷新、MissingCredentials
        // 特判等结构性差异，保留显式实现，不进表。

        private sealed class SimpleProviderSpec
        {
            /// <summary>锁名 / 日志名（与 WithProviderLockAsync、Log 里的 provider= 一致）</summary>
            public required string Name { get; init; }
            public required ProviderType Provider { get; init; }
            public required Func<AppSettings, string?> ApiKey { get; init; }
            public required string MissingKeyZh { get; init; }
            public required string MissingKeyEn { get; init; }
            public required Func<RefreshManager, CancellationToken, Task<(TokenWindow?, TokenWindow?, string?)>> Fetch { get; init; }
            /// <summary>成功写回后的附加动作（余额提醒）；null 表示没有。在 try 内执行，与原实现一致。</summary>
            public Action<RefreshManager, ProviderQuota>? AfterSuccess { get; init; }
        }

        private static readonly SimpleProviderSpec OpenAISpec = new()
        {
            Name = "openai",
            Provider = ProviderType.OpenAI,
            ApiKey = s => s.OpenAIApiKey,
            MissingKeyZh = "请在配置中输入 OpenAI API Key",
            MissingKeyEn = "Please configure OpenAI API Key",
            Fetch = (m, ct) => OpenAIService.Instance.FetchQuotaAsync(
                m.Settings.OpenAIApiKey,
                m.Settings.OpenAIEndpoint,
                m.Settings.OpenAIOrgId,
                ct)
        };

        private static readonly SimpleProviderSpec DeepSeekSpec = new()
        {
            Name = "deepseek",
            Provider = ProviderType.DeepSeek,
            ApiKey = s => s.DeepSeekApiKey,
            MissingKeyZh = "请在配置中输入 DeepSeek API Key",
            MissingKeyEn = "Please configure DeepSeek API Key",
            Fetch = (m, ct) => DeepSeekService.Instance.FetchQuotaAsync(
                m.Settings.DeepSeekApiKey,
                m.Settings.DeepSeekEndpoint,
                m.Settings.DeepSeekModel,
                m.Settings.DeepSeekBalanceAlertThreshold,
                ct),
            AfterSuccess = (m, q) => m.ProcessBalance("deepseek", ProviderType.DeepSeek.GetDisplayName(),
                q.WeeklyWindow, m.Settings.DeepSeekBalanceAlertThreshold)
        };

        private static readonly SimpleProviderSpec VolcengineSpec = new()
        {
            Name = "volcengine",
            Provider = ProviderType.Volcengine,
            ApiKey = s => s.VolcengineApiKey,
            MissingKeyZh = "请在配置中输入火山方舟 API Key",
            MissingKeyEn = "Please configure Volcengine Ark API Key",
            Fetch = (m, ct) => VolcengineService.Instance.FetchQuotaAsync(
                m.Settings.VolcengineApiKey,
                m.Settings.VolcengineEndpoint,
                m.Settings.VolcengineModel,
                ct)
        };

        private static readonly SimpleProviderSpec KimiSpec = new()
        {
            Name = "kimi",
            Provider = ProviderType.Kimi,
            ApiKey = s => s.KimiApiKey,
            MissingKeyZh = "请在配置中输入 KIMI API Key",
            MissingKeyEn = "Please configure KIMI API Key",
            Fetch = (m, ct) => KimiService.Instance.FetchQuotaAsync(
                m.Settings.KimiApiKey,
                m.Settings.KimiEndpoint,
                m.Settings.KimiModel,
                m.Settings.KimiBalanceAlertThreshold,
                ct),
            AfterSuccess = (m, q) => m.ProcessBalance("kimi", ProviderType.Kimi.GetDisplayName(),
                q.WeeklyWindow, m.Settings.KimiBalanceAlertThreshold)
        };

        private static readonly SimpleProviderSpec OpenRouterSpec = new()
        {
            Name = "openrouter",
            Provider = ProviderType.OpenRouter,
            ApiKey = s => s.OpenRouterApiKey,
            MissingKeyZh = "请在配置中输入 OpenRouter API Key",
            MissingKeyEn = "Please configure OpenRouter API Key",
            Fetch = (m, ct) => OpenRouterService.Instance.FetchQuotaAsync(
                m.Settings.OpenRouterApiKey,
                m.Settings.OpenRouterEndpoint,
                m.Settings.OpenRouterBalanceAlertThreshold,
                ct),
            AfterSuccess = (m, q) => m.ProcessBalance("openrouter", ProviderType.OpenRouter.GetDisplayName(),
                q.FiveHourWindow, m.Settings.OpenRouterBalanceAlertThreshold)
        };

        private static readonly SimpleProviderSpec GLMSpec = new()
        {
            Name = "glm",
            Provider = ProviderType.GLM,
            ApiKey = s => s.GLMApiKey,
            MissingKeyZh = "请在配置中输入 GLM API KEY",
            MissingKeyEn = "Please configure GLM API Key",
            Fetch = (m, ct) => GLMService.Instance.FetchQuotaAsync(
                m.Settings.GLMApiKey,
                m.Settings.GLMEndpoint,
                ct)
        };

        /// <summary>六个简单厂商的唯一执行器，骨架逐字取自原六份 RefreshXxxCoreAsync。</summary>
        private async Task RefreshSimpleProviderCoreAsync(SimpleProviderSpec spec, CancellationToken ct, long? generation)
        {
            var quota = Quotas[spec.Provider];
            quota.IsLoading = true;
            quota.ErrorMessage = null;
            NotifyQuotasUpdated();

            if (string.IsNullOrWhiteSpace(spec.ApiKey(Settings)))
            {
                quota.IsAuthorized = false;
                quota.ErrorMessage = LocalizationManager.Instance.IsChinese ? spec.MissingKeyZh : spec.MissingKeyEn;
                quota.IsLoading = false;
                NotifyQuotasUpdated();
                return;
            }

            try
            {
                var (primary, secondary, account) = await spec.Fetch(this, ct);

                if (IsStaleGeneration(generation, spec.Name)) return;

                quota.FiveHourWindow = primary;
                quota.WeeklyWindow = secondary;
                quota.AccountInfo = account;
                quota.IsAuthorized = true;
                quota.HadRefreshError = false;
                quota.LastUpdated = DateTime.Now;

                spec.AfterSuccess?.Invoke(this, quota);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                if (IsStaleGeneration(generation, spec.Name)) return;
                // Key 已配置的失败按「刷新失败」处理：可能是开机网络未就绪等瞬时故障，
                // 打回未授权会让卡片显示「去配置」误导用户。授权态与旧数据保留，成功后回落。
                quota.HadRefreshError = true;
                quota.ErrorMessage = ex.Message;
                Log.Error("provider", $"provider={spec.Name} failed: {ex.Message}");
            }
            finally
            {
                quota.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        public Task RefreshOpenAIAsync(CancellationToken ct = default, long? generation = null) =>
            WithProviderLockAsync(OpenAISpec.Name, ct, () => RefreshSimpleProviderCoreAsync(OpenAISpec, ct, generation));

        public Task RefreshClaudeAsync(CancellationToken ct = default, long? generation = null) =>
            WithProviderLockAsync("claude", ct, () => RefreshClaudeCoreAsync(ct, generation));

        private async Task RefreshClaudeCoreAsync(CancellationToken ct, long? generation)
        {
            var quota = Quotas[ProviderType.ClaudeCode];
            quota.IsLoading = true;
            quota.ErrorMessage = null;
            NotifyQuotasUpdated();

            var localClaude = ClaudeService.Instance.ReadLocalClaudeJson();
            bool hasAnthropicKey = !string.IsNullOrWhiteSpace(Settings.AnthropicApiKey);

            bool foundAuth = false;

            // 1. 订阅额度：实时查远端优先（手填 token → Claude Code 自己的 access token）；
            // 都查不到才退回 ~/.claude.json 缓存，并标注缓存时间。以前没手填 token 时只读缓存，
            // 而缓存只在 Claude Code 自己查用量时才更新，「更新于」却每轮都是新的 —— 这就是「额度刷新不及时」。
            var (remote, remoteError) = await FetchClaudeRemoteUsageAsync(ct);
            if (IsStaleGeneration(generation, "claude")) return;
            if (remote != null)
            {
                var res = remote.Value;
                quota.FiveHourWindow = res.FiveHour;
                quota.WeeklyWindow = res.Weekly;
                // 远端若暂未下发 scoped 周额度，回落本地缓存，任一路有数据即可显示
                quota.ScopedWeeklyWindow = res.ScopedWeekly ?? localClaude?.ScopedWeekly;
                quota.IsAuthorized = true;
                quota.HadRefreshError = false;
                var account = res.Account ?? localClaude?.Account;
                if (account != null) quota.AccountInfo = account;
                quota.IsFromLocalCache = false;
                quota.LocalCacheFetchedAt = null;
                foundAuth = true;
            }
            else if (localClaude != null)
            {
                quota.FiveHourWindow = localClaude.Value.FiveHour;
                quota.WeeklyWindow = localClaude.Value.Weekly;
                quota.ScopedWeeklyWindow = localClaude.Value.ScopedWeekly;
                quota.IsAuthorized = true;
                quota.HadRefreshError = false;
                if (localClaude.Value.Account != null) quota.AccountInfo = localClaude.Value.Account;
                quota.IsFromLocalCache = true;
                quota.LocalCacheFetchedAt = localClaude.Value.FetchedAt;
                foundAuth = true;
            }
            else if (remoteError != null)
            {
                // 本地也没缓存：这是刷新失败不是未配置，留给末尾统一判定
                quota.ErrorMessage = remoteError.Message;
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
                    quota.HadRefreshError = false;
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
                if (quota.ErrorMessage != null)
                {
                    // 配了授权来源但全部失败（多为网络）：按刷新失败处理，不算未配置
                    quota.HadRefreshError = true;
                }
                else
                {
                    quota.IsAuthorized = false;
                    quota.ErrorMessage ??= LocalizationManager.Instance.IsChinese ? "未配置 Anthropic API Key 或 Claude Code 网页/本地授权" : "Anthropic API Key or Claude Code authorization not configured";
                }
            }

            // 与其他厂商对齐：只有真的拿到数据才算一次成功更新
            if (foundAuth)
            {
                quota.LastUpdated = DateTime.Now;
            }
            quota.IsLoading = false;
            NotifyQuotasUpdated();
        }

        /// <summary>
        /// 依次用设置里手填的 token、Claude Code 自己的 OAuth access token 查实时用量，第一个成功的为准。
        /// 都没有或都失败时 Usage 为 null，Error 是最后一次失败的原因（没发出请求则为 null），
        /// 由调用方退回本地缓存。Claude Code 的 token 只用不续：过期就等它自己续期。与 mac 端 fetchClaudeRemoteUsage 同语义。
        /// </summary>
        private async Task<((TokenWindow? FiveHour, TokenWindow? Weekly, TokenWindow? ScopedWeekly, string? Account)? Usage, Exception? Error)> FetchClaudeRemoteUsageAsync(CancellationToken ct)
        {
            Exception? lastError = null;

            var manualToken = Settings.ClaudeToken?.Trim();
            if (!string.IsNullOrEmpty(manualToken))
            {
                try
                {
                    return (await ClaudeService.Instance.FetchRemoteUsageAsync(manualToken, ct), null);
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                catch (Exception ex)
                {
                    lastError = ex;
                    Log.Warn("provider", $"claude 手填 token 查询失败，改用 Claude Code 凭证: {ex.Message}");
                }
            }

            var credential = ClaudeService.Instance.ReadClaudeCodeCredential();
            if (credential == null)
            {
                Log.Notice("provider", "claude 未取得 Claude Code 凭证，退回本地缓存");
                return (null, lastError);
            }
            if (!credential.IsUsable(DateTime.Now))
            {
                Log.Notice("provider", "claude Claude Code access token 已过期，等它自行续期，退回本地缓存");
                return (null, lastError);
            }

            try
            {
                return (await ClaudeService.Instance.FetchRemoteUsageAsync(credential.AccessToken, ct), null);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                Log.Warn("provider", $"claude Claude Code 凭证查询失败，退回本地缓存: {ex.Message}");
                return (null, ex);
            }
        }

        /// <summary>
        /// Gemini 刷新异常的用户可读文案。连接/请求超时（12s ConnectTimeout / 30s HttpClient.Timeout）
        /// 在 .NET 里以 TaskCanceledException("The operation was canceled.") 抛出且预算 token 并未取消，
        /// 直接透传框架英文消息对用户毫无信息量；这里映射成可行动的提示。其余异常保持原消息。
        /// </summary>
        private static string DescribeGeminiFailure(Exception ex) =>
            ex is OperationCanceledException
                ? LocalizationManager.Instance.IsChinese
                    ? "无法连接 Google 服务，请检查网络或代理"
                    : "Cannot reach Google services; check network or proxy"
                : ex.Message;

        public Task RefreshGeminiAsync(CancellationToken ct = default, long? generation = null) =>
            WithProviderLockAsync("gemini", ct, () => RefreshGeminiCoreAsync(ct, generation));

        private async Task RefreshGeminiCoreAsync(CancellationToken ct, long? generation)
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
                    quota.HadRefreshError = false;
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
                        // Key 已配置：失败按「刷新失败」处理（可能是网络未就绪），不算未配置
                        quota.HadRefreshError = true;
                        quota.ErrorMessage = DescribeGeminiFailure(ex);
                        Log.Error("provider", $"provider=gemini failed: {DescribeGeminiFailure(ex)}");
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
                quota.HadRefreshError = false;
                if (account != null) quota.AccountInfo = account;
                quota.LastUpdated = DateTime.Now;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception ex)
            {
                if (IsStaleGeneration(generation, "gemini")) return;
                // 授权来源存在但失败（多为网络未就绪）：不算未配置，保留授权态与旧数据
                quota.HadRefreshError = true;
                quota.ErrorMessage = DescribeGeminiFailure(ex);
                Log.Error("provider", $"provider=gemini failed: {DescribeGeminiFailure(ex)}");
            }
            finally
            {
                quota.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        public Task RefreshDeepSeekAsync(CancellationToken ct = default, long? generation = null) =>
            WithProviderLockAsync(DeepSeekSpec.Name, ct, () => RefreshSimpleProviderCoreAsync(DeepSeekSpec, ct, generation));

        public Task RefreshVolcengineAsync(CancellationToken ct = default, long? generation = null) =>
            WithProviderLockAsync(VolcengineSpec.Name, ct, () => RefreshSimpleProviderCoreAsync(VolcengineSpec, ct, generation));

        public Task RefreshKimiAsync(CancellationToken ct = default, long? generation = null) =>
            WithProviderLockAsync(KimiSpec.Name, ct, () => RefreshSimpleProviderCoreAsync(KimiSpec, ct, generation));

        public Task RefreshOpenRouterAsync(CancellationToken ct = default, long? generation = null) =>
            WithProviderLockAsync(OpenRouterSpec.Name, ct, () => RefreshSimpleProviderCoreAsync(OpenRouterSpec, ct, generation));

        public Task RefreshGLMAsync(CancellationToken ct = default, long? generation = null) =>
            WithProviderLockAsync(GLMSpec.Name, ct, () => RefreshSimpleProviderCoreAsync(GLMSpec, ct, generation));

        public Task RefreshAliyunAsync(CancellationToken ct = default, long? generation = null) =>
            WithProviderLockAsync("aliyun", ct, () => RefreshAliyunCoreAsync(ct, generation));

        private async Task RefreshAliyunCoreAsync(CancellationToken ct, long? generation)
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
                quota.WeeklyWindow = res.LongWindow;
                quota.AccountInfo = res.Account;
                quota.IsAuthorized = true;
                quota.HadRefreshError = false;
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
                            Title = WindowTitle.AccountBalance,
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
                if (ex is AliyunChannelException { Kind: AliyunErrorKind.MissingCredentials })
                {
                    // 百炼没有「Key 为空」前置检查：完全没配凭据在这里浮出，维持未配置态
                    quota.IsAuthorized = false;
                }
                else
                {
                    quota.HadRefreshError = true;
                }
                quota.ErrorMessage = ex.Message;
                Log.Error("provider", $"provider=aliyun failed: {ex.Message}");
            }
            finally
            {
                quota.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        public Task RefreshCustomProviderAsync(CustomProviderConfig config, CancellationToken ct = default, long? generation = null) =>
            WithProviderLockAsync($"custom:{config.Id}", ct, () => RefreshCustomProviderCoreAsync(config, ct, generation));

        private async Task RefreshCustomProviderCoreAsync(CustomProviderConfig config, CancellationToken ct, long? generation)
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
                q.HadRefreshError = false;
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
                q.HadRefreshError = true;
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
        /// 余额窗口刷新成功后的统一处理（差值记录 / 本地历史 / 低余额气泡提醒）。
        /// 状态机与气泡的实现在 BalanceMonitor，这里只做转发，调用点保持不变。
        /// </summary>
        private void ProcessBalance(string providerKey, string displayName, TokenWindow? window, decimal threshold) =>
            _balanceMonitor.Process(providerKey, displayName, window, threshold);

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
                quota.ScopedWeeklyWindow = local.Value.ScopedWeekly;
                quota.IsFromLocalCache = true;
                quota.LocalCacheFetchedAt = local.Value.FetchedAt;
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
                RefreshGeminiAsync().FireAndForget("gemini-import-refresh");
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
            RefreshCustomProviderAsync(config).FireAndForget("custom-provider-add-refresh");
        }

        public void UpdateCustomProvider(CustomProviderConfig config)
        {
            var idx = Settings.CustomProviders.FindIndex(c => c.Id == config.Id);
            if (idx >= 0)
            {
                Settings.CustomProviders[idx] = config;
                SaveSettings();
                RefreshCustomProviderAsync(config).FireAndForget("custom-provider-update-refresh");
            }
        }

        public void RemoveCustomProvider(Guid id)
        {
            Settings.CustomProviders.RemoveAll(c => c.Id == id);
            CustomQuotas.TryRemove(id, out _);
            _balanceMonitor.Forget($"custom:{id}");
            BalanceHistoryStore.Clear($"custom:{id}");
            // 该厂商的两个凭据条目由 SaveSettings 的差异同步删除：它们从 Extract 结果里消失、
            // 但仍在 SecretSync 的 _persistedSecrets 中，ResolveSave 会判成 Delete。不要在这里另开一条删除路径 ——
            // 那会在线程池上与 SecretSync.SyncToStoreAsync 并发改同一个字典。
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
            if (_networkHooked)
            {
                NetworkChange.NetworkAvailabilityChanged -= OnNetworkAvailabilityChanged;
                _networkHooked = false;
            }
            _secretSync.Dispose();
            lock (_timerLock)
            {
                _timer?.Dispose();
            }
            foreach (var sem in _providerLocks.Values)
            {
                sem.Dispose();
            }
            _providerLocks.Clear();
        }
    }
}
