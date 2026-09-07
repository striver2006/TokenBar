using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using Microsoft.Win32;
using Brushes = System.Windows.Media.Brushes;
using Color = System.Windows.Media.Color;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using MessageBox = System.Windows.MessageBox;
using Button = System.Windows.Controls.Button;
using CheckBox = System.Windows.Controls.CheckBox;
using Orientation = System.Windows.Controls.Orientation;
using ComboBox = System.Windows.Controls.ComboBox;
using ComboBoxItem = System.Windows.Controls.ComboBoxItem;
using ListBox = System.Windows.Controls.ListBox;
using ListBoxItem = System.Windows.Controls.ListBoxItem;
using TextBox = System.Windows.Controls.TextBox;
using TokenBar.I18n;
using TokenBar.Models;
using TokenBar.Services;

namespace TokenBar.Views
{
    public partial class SettingsWindow : Window
    {
        private Guid? _editingCustomId;
        private SettingsTab _currentTab = SettingsTab.OpenAI;

        public SettingsWindow(SettingsTab initialTab = SettingsTab.OpenAI)
        {
            InitializeComponent();
            _currentTab = initialTab;
            UpdateLocalization();
            LoadFromSettings();
            SelectTab(initialTab);

            LocalizationManager.Instance.PropertyChanged += (s, e) => Dispatcher.Invoke(UpdateLocalization);
            RefreshManager.Instance.OnQuotasUpdated += () => Dispatcher.Invoke(UpdateStatuses);
            UpdateStatuses();
        }

        public void SelectTab(SettingsTab tab)
        {
            int index = (int)tab;
            if (index >= 0 && index < LstNavigation.Items.Count)
            {
                LstNavigation.SelectedIndex = index;
            }
        }

        private void LstNavigation_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (LstNavigation.SelectedItem is ListBoxItem item && int.TryParse(item.Tag?.ToString(), out int tabIndex))
            {
                SwitchToTab((SettingsTab)tabIndex);
            }
        }

        private void SwitchToTab(SettingsTab tab)
        {
            _currentTab = tab;
            UpdateTitle();

            PnlOpenAI.Visibility = tab == SettingsTab.OpenAI ? Visibility.Visible : Visibility.Collapsed;
            PnlAnthropic.Visibility = tab == SettingsTab.Anthropic ? Visibility.Visible : Visibility.Collapsed;
            PnlGemini.Visibility = tab == SettingsTab.Gemini ? Visibility.Visible : Visibility.Collapsed;
            PnlDeepSeek.Visibility = tab == SettingsTab.DeepSeek ? Visibility.Visible : Visibility.Collapsed;
            PnlVolcengine.Visibility = tab == SettingsTab.Volcengine ? Visibility.Visible : Visibility.Collapsed;
            PnlKimi.Visibility = tab == SettingsTab.Kimi ? Visibility.Visible : Visibility.Collapsed;
            PnlGLM.Visibility = tab == SettingsTab.GLM ? Visibility.Visible : Visibility.Collapsed;
            PnlAliyun.Visibility = tab == SettingsTab.Aliyun ? Visibility.Visible : Visibility.Collapsed;
            PnlCustom.Visibility = tab == SettingsTab.Custom ? Visibility.Visible : Visibility.Collapsed;
            PnlGeneral.Visibility = tab == SettingsTab.General ? Visibility.Visible : Visibility.Collapsed;

            if (tab == SettingsTab.Custom)
            {
                RenderCustomProvidersList();
            }
        }

        private void UpdateTitle()
        {
            var i18n = LocalizationManager.Instance;
            var tabName = _currentTab switch
            {
                SettingsTab.OpenAI => "OpenAI",
                SettingsTab.Anthropic => "Anthropic (Claude)",
                SettingsTab.Gemini => "Google Gemini",
                SettingsTab.DeepSeek => ProviderType.DeepSeek.GetDisplayName(),
                SettingsTab.Volcengine => ProviderType.Volcengine.GetDisplayName(),
                SettingsTab.Kimi => ProviderType.Kimi.GetDisplayName(),
                SettingsTab.GLM => ProviderType.GLM.GetDisplayName(),
                SettingsTab.Aliyun => ProviderType.AliyunBailian.GetDisplayName(),
                SettingsTab.Custom => i18n.CustomProviders,
                SettingsTab.General => i18n.GeneralSettings,
                _ => i18n.GeneralSettings
            };
            this.Title = $"TokenBar - {tabName}";
        }

        private void UpdateLocalization()
        {
            var i18n = LocalizationManager.Instance;
            UpdateTitle();

            // Left Navigation
            TxtNavSubtitle.Text = i18n.OpenSettings.TrimEnd('.');
            TxtNavOpenAI.Text = "OpenAI";
            TxtNavClaude.Text = "Anthropic (Claude)";
            TxtNavGemini.Text = "Google Gemini";
            TxtNavDeepSeek.Text = ProviderType.DeepSeek.GetDisplayName();
            TxtNavVolcengine.Text = ProviderType.Volcengine.GetDisplayName();
            TxtNavKimi.Text = ProviderType.Kimi.GetDisplayName();
            TxtNavGLM.Text = ProviderType.GLM.GetDisplayName();
            TxtNavAliyun.Text = ProviderType.AliyunBailian.GetDisplayName();
            TxtNavCustom.Text = i18n.CustomProviders;
            TxtNavGeneral.Text = i18n.GeneralSettings;

            // Tab 8 Custom
            TxtCustomTitle.Text = i18n.CustomTitle;
            TxtCustomSubtitle.Text = i18n.CustomSubtitle;
            BtnAddCustom.Content = $"＋ {i18n.AddProvider}";
            TxtQuickFillPresets.Text = i18n.QuickFillPresets;
            PopulatePresets();

            // Tab 9 General
            TxtGeneralTitle.Text = i18n.GeneralPreferencesTitle;
            TxtGeneralSubtitle.Text = i18n.GeneralSubtitle;
            TxtLanguageLabel.Text = i18n.InterfaceLanguage;
            CmbItemSystem.Content = i18n.LanguageSystem;
            TxtIntervalLabel.Text = i18n.RefreshInterval;
            ChkHoverPreview.Content = i18n.EnableHoverTitle;
            TxtHoverDesc.Text = i18n.EnableHoverSubtitle;
            ChkLaunchAtLogin.Content = i18n.LaunchAtLoginTitle;
            TxtLaunchDesc.Text = i18n.LaunchAtLoginSubtitle;

            // Footer
            TxtAppAboutFooter.Text = i18n.AppAboutFooter;
            BtnSaveAll.Content = i18n.SaveAllSettings;
            BtnCloseWindow.Content = i18n.Close;

            // Repopulate CmbInterval while preserving selected interval
            int selectedInterval = 5;
            if (CmbInterval.SelectedItem is ComboBoxItem curItem && int.TryParse(curItem.Tag?.ToString(), out int val))
            {
                selectedInterval = val;
            }
            else if (RefreshManager.Instance.Settings != null)
            {
                selectedInterval = RefreshManager.Instance.Settings.RefreshIntervalMinutes;
            }

            CmbInterval.Items.Clear();
            CmbInterval.Items.Add(new ComboBoxItem { Content = i18n.Refresh1Min, Tag = "1" });
            CmbInterval.Items.Add(new ComboBoxItem { Content = i18n.Refresh5Min, Tag = "5" });
            CmbInterval.Items.Add(new ComboBoxItem { Content = i18n.Refresh15Min, Tag = "15" });
            CmbInterval.Items.Add(new ComboBoxItem { Content = i18n.Refresh30Min, Tag = "30" });
            CmbInterval.Items.Add(new ComboBoxItem { Content = i18n.Refresh60Min, Tag = "60" });

            CmbInterval.SelectedIndex = selectedInterval switch
            {
                1 => 0,
                15 => 2,
                30 => 3,
                60 => 4,
                _ => 1
            };

            UpdateStatuses();
        }

        private void PopulatePresets()
        {
            var oldIndex = CmbPresets.SelectedIndex;
            CmbPresets.Items.Clear();
            CmbPresets.Items.Add(new ComboBoxItem { Content = LocalizationManager.Instance.SelectPresetPrompt });
            foreach (var preset in DomesticProviderPreset.AllPresets)
            {
                CmbPresets.Items.Add(new ComboBoxItem { Content = preset.Name, Tag = preset });
            }
            CmbPresets.SelectedIndex = (oldIndex >= 0 && oldIndex < CmbPresets.Items.Count) ? oldIndex : 0;
        }

        private void LoadFromSettings()
        {
            var s = RefreshManager.Instance.Settings;

            // OpenAI
            ChkOpenAIEnabled.IsChecked = s.OpenAIEnabled;
            TxtOpenAIKey.Text = s.OpenAIApiKey;
            TxtOpenAIEndpoint.Text = s.OpenAIEndpoint;
            TxtOpenAIOrgId.Text = s.OpenAIOrgId;

            // Anthropic
            ChkClaudeEnabled.IsChecked = s.ClaudeEnabled;
            TxtAnthropicKey.Text = s.AnthropicApiKey;
            TxtAnthropicEndpoint.Text = s.AnthropicEndpoint;
            TxtClaudeToken.Text = s.ClaudeToken;

            // Gemini
            ChkGeminiEnabled.IsChecked = s.GeminiEnabled;
            TxtGeminiKey.Text = s.GeminiApiKey;
            TxtGeminiEndpoint.Text = s.GeminiEndpoint;
            TxtGeminiToken.Text = s.GeminiToken;

            // DeepSeek
            ChkDeepSeekEnabled.IsChecked = s.DeepSeekEnabled;
            TxtDeepSeekKey.Text = s.DeepSeekApiKey;
            TxtDeepSeekEndpoint.Text = s.DeepSeekEndpoint;
            TxtDeepSeekModel.Text = s.DeepSeekModel;

            // Volcengine
            ChkVolcengineEnabled.IsChecked = s.VolcengineEnabled;
            TxtVolcengineKey.Text = s.VolcengineApiKey;
            TxtVolcengineEndpoint.Text = s.VolcengineEndpoint;
            TxtVolcengineModel.Text = s.VolcengineModel;

            // Kimi
            ChkKimiEnabled.IsChecked = s.KimiEnabled;
            TxtKimiKey.Text = s.KimiApiKey;
            TxtKimiEndpoint.Text = s.KimiEndpoint;
            TxtKimiModel.Text = s.KimiModel;

            // GLM
            ChkGLMEnabled.IsChecked = s.GLMEnabled;
            TxtGLMKey.Text = s.GLMApiKey;
            TxtGLMEndpoint.Text = s.GLMEndpoint;

            // Aliyun
            ChkAliyunEnabled.IsChecked = s.AliyunEnabled;
            TxtAliyunCookie.Text = s.AliyunCookie;

            // General
            CmbLanguage.SelectedIndex = s.Language switch
            {
                AppLanguage.ZhHans => 1,
                AppLanguage.En => 2,
                _ => 0
            };

            int interval = s.RefreshIntervalMinutes;
            CmbInterval.SelectedIndex = interval switch
            {
                1 => 0,
                15 => 2,
                30 => 3,
                60 => 4,
                _ => 1 // 5 min default
            };

            ChkHoverPreview.IsChecked = s.EnableHover;
            ChkLaunchAtLogin.IsChecked = s.LaunchAtLogin || IsRunAtStartupConfigured();
        }

        private void SyncToSettings()
        {
            var s = RefreshManager.Instance.Settings;

            s.OpenAIEnabled = ChkOpenAIEnabled.IsChecked == true;
            s.OpenAIApiKey = TxtOpenAIKey.Text.Trim();
            s.OpenAIEndpoint = TxtOpenAIEndpoint.Text.Trim();
            s.OpenAIOrgId = TxtOpenAIOrgId.Text.Trim();

            s.ClaudeEnabled = ChkClaudeEnabled.IsChecked == true;
            s.AnthropicApiKey = TxtAnthropicKey.Text.Trim();
            s.AnthropicEndpoint = TxtAnthropicEndpoint.Text.Trim();
            s.ClaudeToken = TxtClaudeToken.Text.Trim();

            s.GeminiEnabled = ChkGeminiEnabled.IsChecked == true;
            s.GeminiApiKey = TxtGeminiKey.Text.Trim();
            s.GeminiEndpoint = TxtGeminiEndpoint.Text.Trim();
            s.GeminiToken = TxtGeminiToken.Text.Trim();

            s.DeepSeekEnabled = ChkDeepSeekEnabled.IsChecked == true;
            s.DeepSeekApiKey = TxtDeepSeekKey.Text.Trim();
            s.DeepSeekEndpoint = TxtDeepSeekEndpoint.Text.Trim();
            s.DeepSeekModel = TxtDeepSeekModel.Text.Trim();

            s.VolcengineEnabled = ChkVolcengineEnabled.IsChecked == true;
            s.VolcengineApiKey = TxtVolcengineKey.Text.Trim();
            s.VolcengineEndpoint = TxtVolcengineEndpoint.Text.Trim();
            s.VolcengineModel = TxtVolcengineModel.Text.Trim();

            s.KimiEnabled = ChkKimiEnabled.IsChecked == true;
            s.KimiApiKey = TxtKimiKey.Text.Trim();
            s.KimiEndpoint = TxtKimiEndpoint.Text.Trim();
            s.KimiModel = TxtKimiModel.Text.Trim();

            s.GLMEnabled = ChkGLMEnabled.IsChecked == true;
            s.GLMApiKey = TxtGLMKey.Text.Trim();
            s.GLMEndpoint = TxtGLMEndpoint.Text.Trim();

            s.AliyunEnabled = ChkAliyunEnabled.IsChecked == true;
            s.AliyunCookie = TxtAliyunCookie.Text.Trim();

            s.Language = CmbLanguage.SelectedIndex switch
            {
                1 => AppLanguage.ZhHans,
                2 => AppLanguage.En,
                _ => AppLanguage.System
            };

            if (CmbInterval.SelectedItem is ComboBoxItem item && int.TryParse(item.Tag?.ToString(), out int mins))
            {
                s.RefreshIntervalMinutes = mins;
            }

            s.EnableHover = ChkHoverPreview.IsChecked == true;
            s.LaunchAtLogin = ChkLaunchAtLogin.IsChecked == true;
            SetRunAtStartup(s.LaunchAtLogin);

            RefreshManager.Instance.SaveSettings();
        }

        private void UpdateStatuses()
        {
            var mgr = RefreshManager.Instance;

            void UpdateOne(ProviderType type, TextBlock dot, TextBlock status, TextBlock account)
            {
                if (mgr.Quotas.TryGetValue(type, out var q))
                {
                    if (q.IsAuthorized)
                    {
                        dot.Text = "●";
                        dot.Foreground = new SolidColorBrush(Color.FromRgb(34, 197, 94));
                        status.Text = LocalizationManager.Instance.StatusConnected;
                        account.Text = !string.IsNullOrEmpty(q.AccountInfo) ? $"({q.AccountInfo})" : "";
                    }
                    else
                    {
                        dot.Text = "●";
                        dot.Foreground = new SolidColorBrush(Color.FromRgb(245, 158, 11));
                        status.Text = q.ErrorMessage ?? LocalizationManager.Instance.StatusNotConnected;
                        account.Text = "";
                    }
                }
            }

            UpdateOne(ProviderType.OpenAI, TxtOpenAIStatusDot, TxtOpenAIStatus, TxtOpenAIAccount);
            UpdateOne(ProviderType.ClaudeCode, TxtClaudeStatusDot, TxtClaudeStatus, TxtClaudeAccount);
            UpdateOne(ProviderType.Gemini, TxtGeminiStatusDot, TxtGeminiStatus, TxtGeminiAccount);
            UpdateOne(ProviderType.DeepSeek, TxtDeepSeekStatusDot, TxtDeepSeekStatus, TxtDeepSeekAccount);
            UpdateOne(ProviderType.Volcengine, TxtVolcengineStatusDot, TxtVolcengineStatus, TxtVolcengineAccount);
            UpdateOne(ProviderType.Kimi, TxtKimiStatusDot, TxtKimiStatus, TxtKimiAccount);
            UpdateOne(ProviderType.GLM, TxtGLMStatusDot, TxtGLMStatus, TxtGLMAccount);
            UpdateOne(ProviderType.AliyunBailian, TxtAliyunStatusDot, TxtAliyunStatus, TxtAliyunAccount);

            RenderCustomProvidersList();
        }

        // ==================== Actions ====================

        private async void BtnTestOpenAI_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshOpenAIAsync();
            var q = RefreshManager.Instance.Quotas[ProviderType.OpenAI];
            if (q.IsAuthorized)
                MessageBox.Show("OpenAI 授权连接成功！已检测到接口状态与可用模型。", "提示", MessageBoxButton.OK, MessageBoxImage.Information);
            else
                MessageBox.Show($"OpenAI 连接失败: {q.ErrorMessage}", "提示", MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        private async void BtnTestAnthropicKey_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshClaudeAsync();
            var q = RefreshManager.Instance.Quotas[ProviderType.ClaudeCode];
            if (q.IsAuthorized)
                MessageBox.Show("Anthropic API Key 校验成功！", "提示", MessageBoxButton.OK, MessageBoxImage.Information);
            else
                MessageBox.Show($"Anthropic 校验失败: {q.ErrorMessage}", "提示", MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        private void BtnImportClaudeLocal_Click(object sender, RoutedEventArgs e)
        {
            if (RefreshManager.Instance.ImportClaudeFromLocal())
            {
                MessageBox.Show("成功从 ~/.claude.json 读取并同步本地 Claude CLI 配额！", "提示", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            else
            {
                MessageBox.Show("未在本地找到 ~/.claude.json 配置文件，请先在终端运行 claude 进行登录。", "提示", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private async void BtnSaveClaudeToken_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshClaudeAsync();
            MessageBox.Show("Claude Token 已保存并刷新！", "提示", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        private async void BtnTestGeminiKey_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshGeminiAsync();
            var q = RefreshManager.Instance.Quotas[ProviderType.Gemini];
            if (q.IsAuthorized)
                MessageBox.Show("Google AI Studio API 连接成功！", "提示", MessageBoxButton.OK, MessageBoxImage.Information);
            else
                MessageBox.Show($"连接失败: {q.ErrorMessage}", "提示", MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        private async void BtnClearGeminiKey_Click(object sender, RoutedEventArgs e)
        {
            TxtGeminiKey.Text = "";
            SyncToSettings();
            await RefreshManager.Instance.RefreshGeminiAsync();
        }

        private async void BtnGeminiWebLogin_Click(object sender, RoutedEventArgs e)
        {
            if (RefreshManager.Instance.ImportGeminiFromLocal())
            {
                TxtGeminiToken.Text = RefreshManager.Instance.Settings.GeminiToken;
                await RefreshManager.Instance.RefreshGeminiAsync();
                UpdateStatuses();
                var q = RefreshManager.Instance.Quotas[ProviderType.Gemini];
                MessageBox.Show($"Google 网站登录授权成功！\n已绑定账号: {q.AccountInfo ?? "Google 账号"}", "授权成功", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            else
            {
                var result = MessageBox.Show("未检测到本地 Google 账号凭据。\n\n您可以使用 Antigravity CLI (agy) 完成 Google 登录，或在浏览器中打开 Google 授权页面。\n\n是否立即在浏览器中打开授权页面？", "提示", MessageBoxButton.YesNo, MessageBoxImage.Question);
                if (result == MessageBoxResult.Yes)
                {
                    try
                    {
                        var url = "https://accounts.google.com/o/oauth2/auth?client_id=764086051850-6qr4p6gpi6hn506pt8ejuq83di341hur.apps.googleusercontent.com&redirect_uri=urn:ietf:wg:oauth:2.0:oob&response_type=code&scope=https://www.googleapis.com/auth/cloud-platform%20https://www.googleapis.com/auth/userinfo.email";
                        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo { FileName = url, UseShellExecute = true });
                    }
                    catch { }
                }
            }
        }

        private async void BtnImportGeminiLocal_Click(object sender, RoutedEventArgs e)
        {
            if (RefreshManager.Instance.ImportGeminiFromLocal())
            {
                TxtGeminiToken.Text = RefreshManager.Instance.Settings.GeminiToken;
                await RefreshManager.Instance.RefreshGeminiAsync();
                UpdateStatuses();
                var q = RefreshManager.Instance.Quotas[ProviderType.Gemini];
                MessageBox.Show($"已成功从本地凭据 / Antigravity 读取 Google 凭证！\n当前绑定账号: {q.AccountInfo ?? "Google 账号"}", "提示", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            else
            {
                MessageBox.Show("未检测到本地 Google 凭证。\n请先运行 `agy` 登录 Google 账号，或使用上方 API Key 方式。", "提示", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private async void BtnSaveGeminiToken_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshGeminiAsync();
            MessageBox.Show("Gemini Token 已保存！", "提示", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        private async void BtnTestDeepSeek_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshDeepSeekAsync();
            var q = RefreshManager.Instance.Quotas[ProviderType.DeepSeek];
            if (q.IsAuthorized)
                MessageBox.Show($"DeepSeek 连接成功！{q.AccountInfo}", "提示", MessageBoxButton.OK, MessageBoxImage.Information);
            else
                MessageBox.Show($"DeepSeek 连接失败: {q.ErrorMessage}", "提示", MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        private async void BtnTestVolcengine_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshVolcengineAsync();
            var q = RefreshManager.Instance.Quotas[ProviderType.Volcengine];
            if (q.IsAuthorized)
                MessageBox.Show("火山方舟接入点连接成功！", "提示", MessageBoxButton.OK, MessageBoxImage.Information);
            else
                MessageBox.Show($"火山方舟连接失败: {q.ErrorMessage}", "提示", MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        private async void BtnTestKimi_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshKimiAsync();
            var q = RefreshManager.Instance.Quotas[ProviderType.Kimi];
            if (q.IsAuthorized)
                MessageBox.Show($"KIMI 连接成功！{q.AccountInfo}", "提示", MessageBoxButton.OK, MessageBoxImage.Information);
            else
                MessageBox.Show($"KIMI 连接失败: {q.ErrorMessage}", "提示", MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        private async void BtnTestGLM_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshGLMAsync();
            var q = RefreshManager.Instance.Quotas[ProviderType.GLM];
            if (q.IsAuthorized)
                MessageBox.Show("GLM 智谱 BigModel 授权连接成功！", "提示", MessageBoxButton.OK, MessageBoxImage.Information);
            else
                MessageBox.Show($"GLM 连接失败: {q.ErrorMessage}", "提示", MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        private void BtnOpenAliyunCLI_Click(object sender, RoutedEventArgs e)
        {
            AliyunBailianService.OpenTerminalToLoginCLI();
        }

        private async void BtnTestAliyunCLI_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                var res = await AliyunBailianService.Instance.FetchViaCLIAsync();
                MessageBox.Show("百炼 CLI 配额读取成功！已检测到 7天 与 5小时额度。", "提示", MessageBoxButton.OK, MessageBoxImage.Information);
                _ = RefreshManager.Instance.RefreshAliyunAsync();
            }
            catch (Exception ex)
            {
                MessageBox.Show($"百炼 CLI 读取失败: {ex.Message}", "提示", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private async void BtnTestAliyunCookie_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshAliyunAsync();
            var q = RefreshManager.Instance.Quotas[ProviderType.AliyunBailian];
            if (q.IsAuthorized)
                MessageBox.Show("百炼控制台 Cookie 授权连接成功！", "提示", MessageBoxButton.OK, MessageBoxImage.Information);
            else
                MessageBox.Show($"百炼连接失败: {q.ErrorMessage}", "提示", MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        // ==================== Custom Providers ====================

        private void RenderCustomProvidersList()
        {
            PnlCustomList.Children.Clear();
            var configs = RefreshManager.Instance.Settings.CustomProviders;

            if (configs.Count == 0)
            {
                var emptyNotice = new Border
                {
                    Background = new SolidColorBrush(Color.FromRgb(249, 250, 251)),
                    BorderBrush = new SolidColorBrush(Color.FromRgb(229, 231, 235)),
                    BorderThickness = new Thickness(1),
                    CornerRadius = new CornerRadius(8),
                    Padding = new Thickness(16),
                    Margin = new Thickness(0, 0, 0, 10)
                };
                var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
                stack.Children.Add(new TextBlock
                {
                    Text = LocalizationManager.Instance.NoCustomProviders,
                    FontWeight = FontWeights.Bold,
                    FontSize = 13,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    Margin = new Thickness(0, 0, 0, 4)
                });
                stack.Children.Add(new TextBlock
                {
                    Text = LocalizationManager.Instance.NoCustomProvidersHint,
                    FontSize = 11,
                    Foreground = new SolidColorBrush(Color.FromRgb(107, 114, 128)),
                    HorizontalAlignment = HorizontalAlignment.Center
                });
                emptyNotice.Child = stack;
                PnlCustomList.Children.Add(emptyNotice);
                return;
            }

            foreach (var cfg in configs)
            {
                var card = new Border
                {
                    Background = new SolidColorBrush(Color.FromRgb(249, 250, 251)),
                    BorderBrush = new SolidColorBrush(Color.FromRgb(229, 231, 235)),
                    BorderThickness = new Thickness(1),
                    CornerRadius = new CornerRadius(8),
                    Padding = new Thickness(12, 10, 12, 10),
                    Margin = new Thickness(0, 0, 0, 8)
                };

                var dock = new DockPanel();

                var chk = new CheckBox
                {
                    IsChecked = cfg.IsEnabled,
                    VerticalAlignment = VerticalAlignment.Center,
                    Margin = new Thickness(0, 0, 10, 0)
                };
                chk.Checked += (s, e) => { cfg.IsEnabled = true; RefreshManager.Instance.SaveSettings(); };
                chk.Unchecked += (s, e) => { cfg.IsEnabled = false; RefreshManager.Instance.SaveSettings(); };
                dock.Children.Add(chk);

                var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
                DockPanel.SetDock(actions, Dock.Right);

                var btnEdit = new Button
                {
                    Content = "编辑",
                    Padding = new Thickness(8, 3, 8, 3),
                    Margin = new Thickness(0, 0, 6, 0),
                    Background = Brushes.White,
                    BorderBrush = new SolidColorBrush(Color.FromRgb(209, 213, 219)),
                    FontSize = 11,
                    Cursor = System.Windows.Input.Cursors.Hand
                };
                btnEdit.Click += (s, e) => OpenEditCustomForm(cfg);
                actions.Children.Add(btnEdit);

                var btnDelete = new Button
                {
                    Content = "删除",
                    Padding = new Thickness(8, 3, 8, 3),
                    Background = Brushes.White,
                    BorderBrush = new SolidColorBrush(Color.FromRgb(209, 213, 219)),
                    Foreground = new SolidColorBrush(Color.FromRgb(239, 68, 68)),
                    FontSize = 11,
                    Cursor = System.Windows.Input.Cursors.Hand
                };
                btnDelete.Click += (s, e) =>
                {
                    if (MessageBox.Show($"确定要删除模型厂商「{cfg.Name}」吗？", "删除确认", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
                    {
                        RefreshManager.Instance.RemoveCustomProvider(cfg.Id);
                    }
                };
                actions.Children.Add(btnDelete);
                dock.Children.Add(actions);

                var infoStack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
                var nameRow = new StackPanel { Orientation = Orientation.Horizontal };
                nameRow.Children.Add(new TextBlock { Text = cfg.Name, FontWeight = FontWeights.Bold, FontSize = 12, Margin = new Thickness(0, 0, 8, 0) });
                nameRow.Children.Add(new TextBlock
                {
                    Text = cfg.Protocol switch
                    {
                        ApiProtocol.Anthropic => "Anthropic Messages",
                        ApiProtocol.OpenAIResponses => "OpenAI Responses",
                        _ => "OpenAI Chat"
                    },
                    FontSize = 10,
                    Foreground = new SolidColorBrush(Color.FromRgb(37, 99, 235)),
                    VerticalAlignment = VerticalAlignment.Center
                });
                infoStack.Children.Add(nameRow);

                infoStack.Children.Add(new TextBlock
                {
                    Text = cfg.Endpoint,
                    FontSize = 10,
                    Foreground = new SolidColorBrush(Color.FromRgb(107, 114, 128)),
                    Margin = new Thickness(0, 2, 0, 0)
                });

                dock.Children.Add(infoStack);
                card.Child = dock;
                PnlCustomList.Children.Add(card);
            }
        }

        private void CmbPresets_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (CmbPresets.SelectedItem is ComboBoxItem item && item.Tag is DomesticProviderPreset preset)
            {
                TxtCustomName.Text = preset.Name;
                TxtCustomEndpoint.Text = preset.Endpoint;
                TxtCustomModel.Text = preset.DefaultModel;
                TxtCustomKey.Text = "";
                CmbCustomProtocol.SelectedIndex = preset.ApiProtocol switch
                {
                    ApiProtocol.OpenAIResponses => 1,
                    ApiProtocol.Anthropic => 2,
                    _ => 0
                };
                TxtCustomFormTitle.Text = $"快速添加：{preset.Name}";
                _editingCustomId = null;
                BdCustomForm.Visibility = Visibility.Visible;
            }
        }

        private void BtnAddCustomProvider_Click(object sender, RoutedEventArgs e)
        {
            _editingCustomId = null;
            TxtCustomFormTitle.Text = "添加模型厂商";
            TxtCustomName.Text = "";
            TxtCustomKey.Text = "";
            TxtCustomEndpoint.Text = "http://localhost:3000/v1";
            TxtCustomModel.Text = "";
            CmbCustomProtocol.SelectedIndex = 0;
            BdCustomForm.Visibility = Visibility.Visible;
        }

        private void OpenEditCustomForm(CustomProviderConfig cfg)
        {
            _editingCustomId = cfg.Id;
            TxtCustomFormTitle.Text = $"编辑厂商：{cfg.Name}";
            TxtCustomName.Text = cfg.Name;
            TxtCustomKey.Text = cfg.ApiKey;
            TxtCustomEndpoint.Text = cfg.Endpoint;
            TxtCustomModel.Text = cfg.Model;
            CmbCustomProtocol.SelectedIndex = cfg.Protocol switch
            {
                ApiProtocol.OpenAIResponses => 1,
                ApiProtocol.Anthropic => 2,
                _ => 0
            };
            BdCustomForm.Visibility = Visibility.Visible;
        }

        private void BtnCancelCustomForm_Click(object sender, RoutedEventArgs e)
        {
            BdCustomForm.Visibility = Visibility.Collapsed;
        }

        private void BtnSaveCustomForm_Click(object sender, RoutedEventArgs e)
        {
            var name = TxtCustomName.Text.Trim();
            if (string.IsNullOrEmpty(name))
            {
                MessageBox.Show("请输入厂商名称", "提示", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            var protocol = CmbCustomProtocol.SelectedIndex switch
            {
                1 => ApiProtocol.OpenAIResponses,
                2 => ApiProtocol.Anthropic,
                _ => ApiProtocol.OpenAIChat
            };

            if (_editingCustomId.HasValue)
            {
                var existing = RefreshManager.Instance.Settings.CustomProviders.FirstOrDefault(c => c.Id == _editingCustomId.Value);
                if (existing != null)
                {
                    existing.Name = name;
                    existing.ApiKey = TxtCustomKey.Text.Trim();
                    existing.Endpoint = TxtCustomEndpoint.Text.Trim();
                    existing.Model = TxtCustomModel.Text.Trim();
                    existing.Protocol = protocol;
                    RefreshManager.Instance.UpdateCustomProvider(existing);
                }
            }
            else
            {
                var newConfig = new CustomProviderConfig
                {
                    Name = name,
                    ApiKey = TxtCustomKey.Text.Trim(),
                    Endpoint = TxtCustomEndpoint.Text.Trim(),
                    Model = TxtCustomModel.Text.Trim(),
                    Protocol = protocol,
                    IsEnabled = true
                };
                RefreshManager.Instance.AddCustomProvider(newConfig);
            }

            BdCustomForm.Visibility = Visibility.Collapsed;
            CmbPresets.SelectedIndex = 0;
            RenderCustomProvidersList();
        }

        private void CmbLanguage_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            var lang = CmbLanguage.SelectedIndex switch
            {
                1 => AppLanguage.ZhHans,
                2 => AppLanguage.En,
                _ => AppLanguage.System
            };
            LocalizationManager.Instance.CurrentLanguage = lang;
        }

        private static bool IsRunAtStartupConfigured()
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", false);
                return key?.GetValue("TokenBar") != null;
            }
            catch
            {
                return false;
            }
        }

        private static void SetRunAtStartup(bool enable)
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", true);
                if (key == null) return;

                if (enable)
                {
                    var exePath = Environment.ProcessPath;
                    if (!string.IsNullOrEmpty(exePath))
                    {
                        key.SetValue("TokenBar", $"\"{exePath}\"");
                    }
                }
                else
                {
                    key.DeleteValue("TokenBar", false);
                }
            }
            catch { }
        }

        private void BtnSaveAll_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            var i18n = LocalizationManager.Instance;
            MessageBox.Show(
                i18n.IsChinese ? "设置已保存并生效！" : "Settings saved and applied!",
                i18n.AlertNotice,
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            _ = RefreshManager.Instance.RefreshAllAsync();
        }

        private void BtnClose_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            Close();
        }
    }
}
