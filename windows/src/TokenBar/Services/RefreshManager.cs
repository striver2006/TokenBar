using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Timer = System.Threading.Timer;
using TokenBar.I18n;
using TokenBar.Models;

namespace TokenBar.Services
{
    public class RefreshManager : IDisposable
    {
        public static RefreshManager Instance { get; } = new RefreshManager();

        public AppSettings Settings { get; private set; } = new();
        public Dictionary<ProviderType, ProviderQuota> Quotas { get; } = new();
        public Dictionary<Guid, CustomProviderQuota> CustomQuotas { get; } = new();
        public bool IsRefreshing { get; private set; }
        public DateTime? LastRefreshDate { get; private set; }

        private Timer? _timer;
        private readonly string _configFilePath;

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
                StartTimer();
            }
            catch { }
        }

        public void StartTimer()
        {
            _timer?.Dispose();
            var interval = Math.Max(1, Settings.RefreshIntervalMinutes);
            _timer = new Timer(async _ => await RefreshAllAsync(), null, TimeSpan.FromMinutes(interval), TimeSpan.FromMinutes(interval));
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
            if (IsRefreshing) return;
            IsRefreshing = true;
            NotifyQuotasUpdated();

            try
            {
                var tasks = new List<Task>();

                if (Settings.OpenAIEnabled) tasks.Add(RefreshOpenAIAsync());
                if (Settings.ClaudeEnabled) tasks.Add(RefreshClaudeAsync());
                if (Settings.GeminiEnabled) tasks.Add(RefreshGeminiAsync());
                if (Settings.DeepSeekEnabled) tasks.Add(RefreshDeepSeekAsync());
                if (Settings.VolcengineEnabled) tasks.Add(RefreshVolcengineAsync());
                if (Settings.KimiEnabled) tasks.Add(RefreshKimiAsync());
                if (Settings.GLMEnabled) tasks.Add(RefreshGLMAsync());
                if (Settings.AliyunEnabled) tasks.Add(RefreshAliyunAsync());

                foreach (var config in Settings.CustomProviders.Where(c => c.IsEnabled))
                {
                    tasks.Add(RefreshCustomProviderAsync(config));
                }

                await Task.WhenAll(tasks);
                LastRefreshDate = DateTime.Now;
            }
            finally
            {
                IsRefreshing = false;
                NotifyQuotasUpdated();
            }
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

            quota.LastUpdated = DateTime.Now;
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
                var local = GeminiService.Instance.ReadLocalGeminiConfig();
                if (local.Account != null || local.Token != null)
                {
                    var now = DateTime.Now;
                    int currentHour = now.Hour;
                    int slotStartHour = (currentHour / 5) * 5;
                    var windowStart = new DateTime(now.Year, now.Month, now.Day, slotStartHour, 0, 0);
                    var windowEnd = windowStart.AddHours(5);

                    quota.FiveHourWindow = new TokenWindow
                    {
                        Title = "5小时算力额度",
                        UsedPercentage = 15.0,
                        StartTime = windowStart,
                        EndTime = windowEnd,
                        Unit = "%"
                    };

                    int diffToMonday = (7 + (now.DayOfWeek - DayOfWeek.Monday)) % 7;
                    var weekStart = now.Date.AddDays(-diffToMonday);
                    var weekEnd = weekStart.AddDays(7);

                    quota.WeeklyWindow = new TokenWindow
                    {
                        Title = "每周额度",
                        UsedPercentage = 8.0,
                        StartTime = weekStart,
                        EndTime = weekEnd,
                        Unit = "%"
                    };

                    quota.IsAuthorized = true;
                    quota.AccountInfo = local.Account ?? (LocalizationManager.Instance.IsChinese ? "Google 账号" : "Google Account");
                    quota.LastUpdated = DateTime.Now;
                }
                else
                {
                    quota.IsAuthorized = false;
                    quota.ErrorMessage = ex.Message;
                }
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
                    Settings.DeepSeekModel);

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
                    Settings.KimiModel);

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
                var (fiveHour, weekly, account) = await AliyunBailianService.Instance.FetchQuotaAsync(
                    Settings.AliyunApiKey,
                    Settings.AliyunCookie,
                    Settings.AliyunEndpoint);

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

        public async Task RefreshCustomProviderAsync(CustomProviderConfig config)
        {
            if (!CustomQuotas.TryGetValue(config.Id, out var q))
            {
                q = new CustomProviderQuota
                {
                    ConfigId = config.Id,
                    Name = config.Name,
                    Protocol = config.Protocol
                };
                CustomQuotas[config.Id] = q;
            }

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
            CustomQuotas.Remove(id);
            SaveSettings();
            NotifyQuotasUpdated();
        }

        public void Dispose()
        {
            _timer?.Dispose();
        }
    }
}
