using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
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

            StartTimer();
            _ = RefreshAllAsync();
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

        private void StartTimer()
        {
            _timer?.Dispose();
            var interval = Math.Max(1, Settings.RefreshIntervalMinutes);
            _timer = new Timer(async _ => await RefreshAllAsync(), null, TimeSpan.FromMinutes(interval), TimeSpan.FromMinutes(interval));
        }

        public async Task RefreshAllAsync()
        {
            if (IsRefreshing) return;
            IsRefreshing = true;
            OnQuotasUpdated?.Invoke();

            try
            {
                // Simulate refresh calls or fetch from configured providers
                await Task.Delay(500);
                LastRefreshDate = DateTime.Now;
            }
            finally
            {
                IsRefreshing = false;
                OnQuotasUpdated?.Invoke();
            }
        }

        public void Dispose()
        {
            _timer?.Dispose();
        }
    }
}
