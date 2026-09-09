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

        private Timer? _timer;
        // 当前定时器生效的间隔，用于判断设置变更是否真的需要重建定时器
        private int? _activeIntervalMinutes;
        private readonly string _configFilePath;

        // 余额窗口的展示辅助状态（较上次差值 + 低余额提醒状态机），进程内有效
        private readonly object _balanceLock = new();
        private readonly Dictionary<string, decimal> _lastBalance = new();
        private readonly HashSet<string> _balanceAlerted = new();

        public event Action? OnQuotasUpdated;

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
            StartTimer();
            _ = RefreshAllAsync();
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
            catch
            {
                Settings = new AppSettings();
            }

            LocalizationManager.Instance.CurrentLanguage = Settings.Language;
        }

        public void SaveSettings()
        {
            try
            {
                var json = JsonSerializer.Serialize(Settings, new JsonSerializerOptions { WriteIndented = true });
                File.WriteAllText(_configFilePath, json);
                LocalizationManager.Instance.CurrentLanguage = Settings.Language;
                // 只有间隔真的变了才重建定时器：设置页里切厂商开关、改语言等都会走到这里，
                // 每次都 Dispose 重建会把计时相位打回零，间隔较长时可能永远刷不到。
                if (_activeIntervalMinutes != Settings.RefreshIntervalMinutes)
                {
                    StartTimer();
                }
            }
            catch { }
        }

        public void StartTimer()
        {
            _timer?.Dispose();
            var interval = Math.Max(1, Settings.RefreshIntervalMinutes);
            _timer = new Timer(TimerTickAsync, null, TimeSpan.FromMinutes(interval), TimeSpan.FromMinutes(interval));
            _activeIntervalMinutes = Settings.RefreshIntervalMinutes;
        }

        // TimerCallback 返回 void，异常一旦逃出这个 async void 方法就会终止进程，
        // 因此这里必须吞掉所有异常（各厂商方法内部已各自记录错误信息）。
        private async void TimerTickAsync(object? state)
        {
            try
            {
                await RefreshAllAsync();
            }
            catch { }
        }

        /// <summary>数据过期时才刷新，用于系统唤醒这类"可能已经错过若干个周期"的补刷场景</summary>
        public async Task RefreshIfStaleAsync(TimeSpan olderThan)
        {
            if (LastRefreshDate is DateTime last && DateTime.Now - last < olderThan) return;
            await RefreshAllAsync();
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

        public async Task RefreshAllAsync()
        {
            // 原子地抢占闸门，避免定时器（线程池）与手动刷新（UI 线程）同时进入
            if (Interlocked.CompareExchange(ref _refreshing, 1, 0) != 0) return;
            NotifyQuotasUpdated();

            // 各刷新方法只在成功拿到数据时才推进自己的 LastUpdated，据此判断本轮是否有实际收获
            var updatedBefore = LatestQuotaUpdate();

            try
            {
                var tasks = new List<Task>();

                if (Settings.OpenAIEnabled) tasks.Add(RefreshOpenAIAsync());
                if (Settings.ClaudeEnabled) tasks.Add(RefreshClaudeAsync());
                if (Settings.GeminiEnabled) tasks.Add(RefreshGeminiAsync());
                if (Settings.DeepSeekEnabled) tasks.Add(RefreshDeepSeekAsync());
                if (Settings.VolcengineEnabled) tasks.Add(RefreshVolcengineAsync());
                if (Settings.KimiEnabled) tasks.Add(RefreshKimiAsync());
                if (Settings.OpenRouterEnabled) tasks.Add(RefreshOpenRouterAsync());
                if (Settings.GLMEnabled) tasks.Add(RefreshGLMAsync());
                if (Settings.AliyunEnabled) tasks.Add(RefreshAliyunAsync());

                foreach (var config in Settings.CustomProviders.Where(c => c.IsEnabled))
                {
                    tasks.Add(RefreshCustomProviderAsync(config));
                }

                await Task.WhenAll(tasks);

                // 全部厂商都失败时不推进时间戳，避免界面显示"刚刚更新"却是一屏旧数据
                var after = LatestQuotaUpdate();
                if (after.HasValue && after != updatedBefore)
                {
                    LastRefreshDate = after;
                }
            }
            finally
            {
                Volatile.Write(ref _refreshing, 0);
                NotifyQuotasUpdated();
            }
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

        public async Task RefreshOpenAIAsync()
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
                    Settings.OpenAIOrgId);

                quota.FiveHourWindow = primary;
                quota.WeeklyWindow = secondary;
                quota.AccountInfo = account;
                quota.IsAuthorized = true;
                quota.LastUpdated = DateTime.Now;
            }
            catch (Exception ex)
            {
                quota.IsAuthorized = false;
                quota.ErrorMessage = ex.Message;
            }
            finally
            {
                quota.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        public async Task RefreshClaudeAsync()
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
                    var (fiveHour, weekly, account) = await ClaudeService.Instance.FetchRemoteUsageAsync(Settings.ClaudeToken);
                    quota.FiveHourWindow = fiveHour;
                    quota.WeeklyWindow = weekly;
                    quota.IsAuthorized = true;
                    if (account != null) quota.AccountInfo = account;
                    foundAuth = true;
                }
                catch
                {
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
                        Settings.AnthropicEndpoint);

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
                catch (Exception ex)
                {
                    if (!foundAuth)
                    {
                        quota.ErrorMessage = ex.Message;
                    }
                }
            }

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

        public async Task RefreshGeminiAsync()
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
                        Settings.GeminiEndpoint);

                    quota.FiveHourWindow = fiveHour;
                    quota.WeeklyWindow = weekly;
                    quota.IsAuthorized = true;
                    quota.AccountInfo = account;
                    quota.LastUpdated = DateTime.Now;
                    quota.IsLoading = false;
                    NotifyQuotasUpdated();
                    return;
                }
                catch (Exception ex)
                {
                    var local = GeminiService.Instance.ReadLocalGeminiConfig();
                    bool hasOAuth = !string.IsNullOrWhiteSpace(Settings.GeminiToken) || local.Account != null || local.Token != null;
                    if (!hasOAuth)
                    {
                        quota.IsAuthorized = false;
                        quota.ErrorMessage = ex.Message;
                        quota.IsLoading = false;
                        NotifyQuotasUpdated();
                        return;
                    }
                }
            }

            // 2. OAuth Web Login / Local Credentials Fallback
            try
            {
                var (fiveHour, weekly, account) = await GeminiService.Instance.FetchQuotaAsync(Settings.GeminiToken);
                quota.FiveHourWindow = fiveHour;
                quota.WeeklyWindow = weekly;
                quota.IsAuthorized = true;
                if (account != null) quota.AccountInfo = account;
                quota.LastUpdated = DateTime.Now;
            }
            catch (Exception ex)
            {
                quota.IsAuthorized = false;
                quota.ErrorMessage = ex.Message;
            }
            finally
            {
                quota.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        public async Task RefreshDeepSeekAsync()
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
                    Settings.DeepSeekBalanceAlertThreshold);

                quota.FiveHourWindow = primary;
                quota.WeeklyWindow = secondary;
                quota.AccountInfo = account;
                quota.IsAuthorized = true;
                quota.LastUpdated = DateTime.Now;

                ProcessBalance("deepseek", ProviderType.DeepSeek.GetDisplayName(),
                    quota.WeeklyWindow, Settings.DeepSeekBalanceAlertThreshold);
            }
            catch (Exception ex)
            {
                quota.IsAuthorized = false;
                quota.ErrorMessage = ex.Message;
            }
            finally
            {
                quota.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        public async Task RefreshVolcengineAsync()
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
                    Settings.VolcengineModel);

                quota.FiveHourWindow = primary;
                quota.WeeklyWindow = secondary;
                quota.AccountInfo = account;
                quota.IsAuthorized = true;
                quota.LastUpdated = DateTime.Now;
            }
            catch (Exception ex)
            {
                quota.IsAuthorized = false;
                quota.ErrorMessage = ex.Message;
            }
            finally
            {
                quota.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        public async Task RefreshKimiAsync()
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
                    Settings.KimiBalanceAlertThreshold);

                quota.FiveHourWindow = primary;
                quota.WeeklyWindow = secondary;
                quota.AccountInfo = account;
                quota.IsAuthorized = true;
                quota.LastUpdated = DateTime.Now;

                ProcessBalance("kimi", ProviderType.Kimi.GetDisplayName(),
                    quota.WeeklyWindow, Settings.KimiBalanceAlertThreshold);
            }
            catch (Exception ex)
            {
                quota.IsAuthorized = false;
                quota.ErrorMessage = ex.Message;
            }
            finally
            {
                quota.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        public async Task RefreshOpenRouterAsync()
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
                    Settings.OpenRouterBalanceAlertThreshold);

                quota.FiveHourWindow = primary;
                quota.WeeklyWindow = secondary;
                quota.AccountInfo = account;
                quota.IsAuthorized = true;
                quota.LastUpdated = DateTime.Now;

                ProcessBalance("openrouter", ProviderType.OpenRouter.GetDisplayName(),
                    quota.FiveHourWindow, Settings.OpenRouterBalanceAlertThreshold);
            }
            catch (Exception ex)
            {
                quota.IsAuthorized = false;
                quota.ErrorMessage = ex.Message;
            }
            finally
            {
                quota.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        public async Task RefreshGLMAsync()
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
                    Settings.GLMEndpoint);

                quota.FiveHourWindow = fiveHour;
                quota.WeeklyWindow = weekly;
                quota.AccountInfo = account;
                quota.IsAuthorized = true;
                quota.LastUpdated = DateTime.Now;
            }
            catch (Exception ex)
            {
                quota.IsAuthorized = false;
                quota.ErrorMessage = ex.Message;
            }
            finally
            {
                quota.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        public async Task RefreshAliyunAsync()
        {
            var quota = Quotas[ProviderType.AliyunBailian];
            quota.IsLoading = true;
            quota.ErrorMessage = null;
            NotifyQuotasUpdated();

            try
            {
                var credentials = AliyunBailianService.ResolveCredentials(Settings);
                var res = await AliyunBailianService.Instance.FetchQuotaAsync(credentials);

                // 新签发的控制台令牌落进凭据管理器，下次刷新直接复用，避免重复签发
                if (!string.IsNullOrEmpty(res.RefreshedToken))
                {
                    CredentialSecretStore.Instance.Set(
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
                            .FetchAccountBalanceAsync(credentials);
                        quota.BalanceWindow = new TokenWindow
                        {
                            Title = LocalizationManager.Instance.IsChinese ? "账户余额" : "Balance",
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
                    catch { }
                }
            }
            catch (Exception ex)
            {
                quota.IsAuthorized = false;
                quota.ErrorMessage = ex.Message;
            }
            finally
            {
                quota.IsLoading = false;
                NotifyQuotasUpdated();
            }
        }

        public async Task RefreshCustomProviderAsync(CustomProviderConfig config)
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
                var (primary, secondary, account) = await CustomProviderService.Instance.FetchQuotaAsync(config);
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
            catch (Exception ex)
            {
                q.IsAuthorized = false;
                q.ErrorMessage = ex.Message;
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
            _timer?.Dispose();
        }
    }
}
