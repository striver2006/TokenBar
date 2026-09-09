using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
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
using TokenBar.Helpers;
using TokenBar.I18n;
using TokenBar.Models;
using TokenBar.Services;

namespace TokenBar.Views
{
    public partial class SettingsWindow : Window
    {
        private Guid? _editingCustomId;
        private SettingsTab _currentTab = SettingsTab.OpenAI;

        /// <summary>
        /// AccessKey Secret 的读取状态。Unavailable 是关键态：此时 PwdAliyunAkSecret
        /// 为空**只代表这一轮没读到**，不代表凭据管理器里没有。把它当成「用户想清空」
        /// 去执行删除，就会抹掉真实存在的账号级长期凭证。
        /// </summary>
        private SecretLookupKind _aliyunSecretState = SecretLookupKind.Unavailable;
        /// <summary>保存按钮的在途标记：写凭据现在是 async，不挡住会重入</summary>
        private bool _isSavingAliyunAk;

        public SettingsWindow(SettingsTab initialTab = SettingsTab.OpenAI)
        {
            InitializeComponent();
            _currentTab = initialTab;
            ApplyTabIcons();
            UpdateLocalization();
            LoadFromSettings();
            SelectTab(initialTab);

            LocalizationManager.Instance.PropertyChanged += (s, e) => Dispatcher.Invoke(UpdateLocalization);
            RefreshManager.Instance.OnQuotasUpdated += () => Dispatcher.Invoke(UpdateStatuses);
            UpdateStatuses();

            // 凭据读取挂到 Loaded：构造函数不能 await，而同步的 Cred* P/Invoke 在
            // UI 线程上会卡住窗口。对应 mac 端 SettingsView 的 .task 修饰符。
            Loaded += async (_, _) => await LoadAliyunSecretAsync();
        }

        /// <summary>
        /// 为左侧导航与各选项卡标题设置厂商标识矢量图标（几何与配色对齐 macOS 端 SF Symbol 方案）。
        /// </summary>
        private void ApplyTabIcons()
        {
            SetIcon(NavIconOpenAI, SettingsTab.OpenAI);
            SetIcon(NavIconClaude, SettingsTab.Anthropic);
            SetIcon(NavIconGemini, SettingsTab.Gemini);
            SetIcon(NavIconDeepSeek, SettingsTab.DeepSeek);
            SetIcon(NavIconVolcengine, SettingsTab.Volcengine);
            SetIcon(NavIconKimi, SettingsTab.Kimi);
            SetIcon(NavIconOpenRouter, SettingsTab.OpenRouter);
            SetIcon(NavIconGLM, SettingsTab.GLM);
            SetIcon(NavIconAliyun, SettingsTab.Aliyun);
            SetIcon(NavIconCustom, SettingsTab.Custom);
            SetIcon(NavIconDisplayOrder, SettingsTab.DisplayOrder);
            SetIcon(NavIconGeneral, SettingsTab.General);

            SetIcon(IconOpenAI, SettingsTab.OpenAI);
            SetIcon(IconAnthropic, SettingsTab.Anthropic);
            SetIcon(IconGemini, SettingsTab.Gemini);
            SetIcon(IconDeepSeek, SettingsTab.DeepSeek);
            SetIcon(IconVolcengine, SettingsTab.Volcengine);
            SetIcon(IconKimi, SettingsTab.Kimi);
            SetIcon(IconOpenRouter, SettingsTab.OpenRouter);
            SetIcon(IconGLM, SettingsTab.GLM);
            SetIcon(IconAliyun, SettingsTab.Aliyun);
            SetIcon(IconCustom, SettingsTab.Custom);
            SetIcon(IconDisplayOrder, SettingsTab.DisplayOrder);
            SetIcon(IconGeneral, SettingsTab.General);
        }

        private static void SetIcon(System.Windows.Shapes.Path icon, SettingsTab tab)
        {
            icon.Data = ProviderIcons.GetTabIconGeometry(tab);
            icon.Fill = new SolidColorBrush(ProviderIcons.GetTabIconColor(tab));
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
            PnlOpenRouter.Visibility = tab == SettingsTab.OpenRouter ? Visibility.Visible : Visibility.Collapsed;
            PnlGLM.Visibility = tab == SettingsTab.GLM ? Visibility.Visible : Visibility.Collapsed;
            PnlAliyun.Visibility = tab == SettingsTab.Aliyun ? Visibility.Visible : Visibility.Collapsed;
            PnlCustom.Visibility = tab == SettingsTab.Custom ? Visibility.Visible : Visibility.Collapsed;
            PnlDisplayOrder.Visibility = tab == SettingsTab.DisplayOrder ? Visibility.Visible : Visibility.Collapsed;
            PnlGeneral.Visibility = tab == SettingsTab.General ? Visibility.Visible : Visibility.Collapsed;

            if (tab == SettingsTab.Custom)
            {
                RenderCustomProvidersList();
            }

            if (tab == SettingsTab.DisplayOrder)
            {
                RenderOrderList();
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
                SettingsTab.OpenRouter => ProviderType.OpenRouter.GetDisplayName(),
                SettingsTab.GLM => ProviderType.GLM.GetDisplayName(),
                SettingsTab.Aliyun => ProviderType.AliyunBailian.GetDisplayName(),
                SettingsTab.Custom => i18n.CustomProviders,
                SettingsTab.DisplayOrder => i18n.DisplayOrder,
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
            TxtNavOpenRouter.Text = ProviderType.OpenRouter.GetDisplayName();
            TxtNavGLM.Text = ProviderType.GLM.GetDisplayName();
            TxtNavAliyun.Text = ProviderType.AliyunBailian.GetDisplayName();
            TxtNavCustom.Text = i18n.CustomProviders;
            TxtNavDisplayOrder.Text = i18n.DisplayOrder;
            TxtNavGeneral.Text = i18n.GeneralSettings;

            // Tab 0: OpenAI
            TxtOpenAITitle.Text = i18n.OpenAITitle;
            TxtOpenAISubtitle.Text = i18n.OpenAISubtitle;
            ChkOpenAIEnabled.Content = i18n.EnableMonitoring;
            TxtOpenAIKeyLabel.Text = i18n.ApiKeyLabel;
            TxtOpenAIKeyHint.Text = i18n.HintOpenAIKey;
            TxtOpenAIEndpointLabel.Text = i18n.ApiEndpointLabel;
            TxtOpenAIEndpointHint.Text = i18n.HintOpenAIEndpoint;
            TxtOpenAIOrgIdLabel.Text = i18n.OrgIdLabel;
            BtnTestOpenAI.Content = i18n.SaveAndTest;

            // Tab 1: Anthropic
            TxtClaudeTitle.Text = i18n.AnthropicTitle;
            TxtClaudeSubtitle.Text = i18n.AnthropicSubtitle;
            ChkClaudeEnabled.Content = i18n.EnableMonitoring;
            TxtClaudeMethod1Title.Text = i18n.MethodAnthropicKey;
            TxtAnthropicKeyLabel.Text = $"{i18n.ApiKeyLabel}:";
            TxtAnthropicEndpointLabel.Text = i18n.LabelApiEndpointColon;
            BtnTestAnthropicKey.Content = i18n.SaveAndTestAnthropicKey;
            TxtClaudeMethod2Title.Text = i18n.MethodClaudeSubscription;
            BtnImportClaudeLocal.Content = i18n.BtnReadLocalCLIAuth;
            TxtClaudeManualTokenLabel.Text = i18n.LabelClaudeManualToken;
            BtnSaveClaudeToken.Content = i18n.Save;

            // Tab 2: Gemini
            TxtGeminiTitle.Text = i18n.GeminiTitle;
            TxtGeminiSubtitle.Text = i18n.GeminiSubtitle;
            ChkGeminiEnabled.Content = i18n.EnableMonitoring;
            TxtGeminiMethod1Title.Text = i18n.MethodGeminiApiKey;
            TxtGeminiKeyLabel.Text = $"{i18n.ApiKeyLabel} (AIzaSy...):";
            TxtGeminiEndpointLabel.Text = i18n.LabelApiEndpointColon;
            BtnTestGeminiKey.Content = i18n.SaveAndTest;
            BtnClearGeminiKey.Content = i18n.ClearKey;
            TxtGeminiMethod2Title.Text = i18n.MethodGeminiOAuth;
            BtnGeminiWebLogin.Content = i18n.BtnGoogleWebLogin;
            BtnImportGeminiLocal.Content = i18n.BtnReadLocalGeminiConfig;
            TxtGeminiManualTokenLabel.Text = i18n.LabelManualGeminiToken;
            BtnSaveGeminiToken.Content = i18n.Save;

            // Tab 3: DeepSeek
            TxtDeepSeekTitle.Text = i18n.DeepSeekTitle;
            TxtDeepSeekSubtitle.Text = i18n.DeepSeekSubtitle;
            ChkDeepSeekEnabled.Content = i18n.EnableMonitoring;
            TxtDeepSeekKeyLabel.Text = i18n.ApiKeyLabel;
            TxtDeepSeekKeyHint.Text = i18n.HintDeepSeekKey;
            TxtDeepSeekEndpointLabel.Text = i18n.ApiEndpointLabel;
            TxtDeepSeekModelLabel.Text = i18n.LabelDefaultModel;
            TxtDeepSeekThresholdLabel.Text = i18n.BalanceThresholdLabel;
            TxtDeepSeekThresholdHint.Text = i18n.BalanceThresholdHint;
            BtnTestDeepSeek.Content = i18n.SaveAndTest;

            // Tab 4: Volcengine
            TxtVolcengineTitle.Text = i18n.VolcengineTitle;
            TxtVolcengineSubtitle.Text = i18n.VolcengineSubtitle;
            ChkVolcengineEnabled.Content = i18n.EnableMonitoring;
            TxtVolcengineKeyLabel.Text = $"{i18n.VolcengineTitle} {i18n.ApiKeyLabel}";
            TxtVolcengineEndpointLabel.Text = i18n.ApiEndpointLabel;
            TxtVolcengineModelLabel.Text = i18n.LabelVolcengineEndpointId;
            BtnTestVolcengine.Content = i18n.SaveAndTest;

            // Tab 5: Kimi
            TxtKimiTitle.Text = i18n.KimiTitle;
            TxtKimiSubtitle.Text = i18n.KimiSubtitle;
            ChkKimiEnabled.Content = i18n.EnableMonitoring;
            TxtKimiKeyLabel.Text = $"{i18n.KimiTitle} {i18n.ApiKeyLabel}";
            TxtKimiEndpointLabel.Text = i18n.ApiEndpointLabel;
            TxtKimiModelLabel.Text = i18n.LabelModelName;
            TxtKimiThresholdLabel.Text = i18n.BalanceThresholdLabel;
            TxtKimiThresholdHint.Text = i18n.BalanceThresholdHint;
            BtnTestKimi.Content = i18n.SaveAndTest;

            // Tab 6: OpenRouter
            TxtOpenRouterTitle.Text = i18n.OpenRouterTitle;
            TxtOpenRouterSubtitle.Text = i18n.OpenRouterSubtitle;
            ChkOpenRouterEnabled.Content = i18n.EnableMonitoring;
            TxtOpenRouterKeyLabel.Text = i18n.ApiKeyLabel;
            TxtOpenRouterKeyHint.Text = i18n.HintOpenRouterKey;
            TxtOpenRouterEndpointLabel.Text = i18n.ApiEndpointLabel;
            TxtOpenRouterThresholdLabel.Text = i18n.BalanceThresholdLabel;
            TxtOpenRouterThresholdHint.Text = i18n.BalanceThresholdHint;
            BtnTestOpenRouter.Content = i18n.SaveAndTest;

            // Tab 6: GLM
            TxtGLMTitle.Text = i18n.GLMTitle;
            TxtGLMSubtitle.Text = i18n.GLMSubtitle;
            ChkGLMEnabled.Content = i18n.EnableMonitoring;
            TxtGLMKeyLabel.Text = i18n.LabelGLMKey;
            TxtGLMEndpointLabel.Text = i18n.ApiEndpointLabel;
            BtnTestGLM.Content = i18n.SaveAndTest;

            // Tab 7: Aliyun
            TxtAliyunTitle.Text = i18n.AliyunTitle;
            TxtAliyunSubtitle.Text = i18n.AliyunSubtitle;
            ChkAliyunEnabled.Content = i18n.EnableMonitoring;
            // 方式一：AccessKey（推荐）
            TxtAliyunMethodAKTitle.Text = i18n.AliyunMethodAKTitle;
            TxtAliyunMethodAKDesc.Text = i18n.AliyunMethodAKDesc;
            BtnOpenRamConsole.Content = i18n.BtnAliyunOpenRAMConsole;
            ExpAliyunRamHowTo.Header = i18n.AliyunRAMHowToTitle;
            TxtAliyunRamHowToSteps.Text = i18n.AliyunRAMHowToSteps;
            TxtAliyunAkIdLabel.Text = i18n.LabelAliyunAccessKeyId;
            TxtAliyunAkSecretLabel.Text = i18n.LabelAliyunAccessKeySecret;
            TxtAliyunRegionLabel.Text = i18n.LabelAliyunConsoleRegion;
            TxtAliyunSiteLabel.Text = i18n.LabelAliyunConsoleSite;
            TxtAliyunBalanceThresholdLabel.Text = i18n.LabelAliyunBalanceThreshold;
            ExpAliyunAdvanced.Header = i18n.AliyunAdvancedTitle;
            TxtAliyunSwitchAgentLabel.Text = i18n.LabelAliyunSwitchAgent;
            TxtAliyunSwitchAgentHint.Text = i18n.HintAliyunSwitchAgent;
            ChkAliyunReuseCliConfig.Content = i18n.ToggleAliyunReuseCliConfig;
            TxtAliyunReuseCliHint.Text = i18n.HintAliyunReuseCliConfig;
            BtnTestAliyunAK.Content = i18n.BtnAliyunSaveAndTestAK;
            // 方式二：CLI（备用）／方式三：Cookie（兜底）
            TxtAliyunMethod1Title.Text = i18n.AliyunMethodCLITitle;
            TxtAliyunMethod1Desc.Text = i18n.AliyunMethodCLIDesc;
            BtnOpenAliyunCLI.Content = i18n.BtnAliyunTerminalCLI;
            BtnTestAliyunCLI.Content = i18n.BtnAliyunTestCLI;
            TxtAliyunMethod2Title.Text = i18n.AliyunMethodCookieTitle;
            TxtAliyunCookieLabel.Text = i18n.LabelAliyunCookie;
            BtnTestAliyunCookie.Content = i18n.BtnAliyunSaveCookie;

            // Tab 8 Custom Form Elements
            TxtCustomNameLabel.Text = i18n.ProviderNameLabel + ":";
            TxtCustomProtocolLabel.Text = i18n.ProtocolTypeLabel + ":";
            TxtCustomKeyLabel.Text = i18n.ApiKeyLabel + ":";
            TxtCustomEndpointLabel.Text = i18n.LabelCustomBaseUrl;
            TxtCustomModelLabel.Text = i18n.LabelCustomModelOptional;
            TxtCustomThresholdLabel.Text = i18n.IsChinese ? "余额提醒阈值 (选填，按账户币种):" : "Balance Alert Threshold (optional, account currency):";
            TxtCustomCookieLabel.Text = i18n.ConsoleCookieLabel;
            TxtCustomCookieHint.Text = i18n.ConsoleCookieHint;
            BtnCancelCustomForm.Content = i18n.Cancel;
            BtnSaveCustomForm.Content = i18n.BtnSaveProvider;
            if (_editingCustomId == null)
            {
                TxtCustomFormTitle.Text = i18n.FormTitleAddProvider;
            }

            // Tab 8 Custom
            TxtCustomTitle.Text = i18n.CustomTitle;
            TxtCustomSubtitle.Text = i18n.CustomSubtitle;
            BtnAddCustom.Content = $"＋ {i18n.AddProvider}";
            TxtQuickFillPresets.Text = i18n.QuickFillPresets;
            PopulatePresets();

            // Tab 9 Display Order
            TxtDisplayOrderTitle.Text = i18n.DisplayOrder;
            TxtDisplayOrderSubtitle.Text = i18n.DisplayOrderSubtitle;
            TxtDisplayOrderHint.Text = i18n.DisplayOrderHint;
            BtnResetOrder.Content = i18n.ResetOrder;
            if (_currentTab == SettingsTab.DisplayOrder)
            {
                RenderOrderList();
            }

            // Tab 10 General
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
                CmbPresets.Items.Add(new ComboBoxItem { Content = preset.LocalizedName, Tag = preset });
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
            TxtDeepSeekThreshold.Text = s.DeepSeekBalanceAlertThreshold.ToString("0.##");

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
            TxtKimiThreshold.Text = s.KimiBalanceAlertThreshold.ToString("0.##");

            // OpenRouter
            ChkOpenRouterEnabled.IsChecked = s.OpenRouterEnabled;
            TxtOpenRouterKey.Text = s.OpenRouterApiKey;
            TxtOpenRouterEndpoint.Text = s.OpenRouterEndpoint;
            TxtOpenRouterThreshold.Text = s.OpenRouterBalanceAlertThreshold.ToString("0.##");

            // GLM
            ChkGLMEnabled.IsChecked = s.GLMEnabled;
            TxtGLMKey.Text = s.GLMApiKey;
            TxtGLMEndpoint.Text = s.GLMEndpoint;

            // Aliyun
            ChkAliyunEnabled.IsChecked = s.AliyunEnabled;
            TxtAliyunCookie.Text = s.AliyunCookie;
            TxtAliyunAkId.Text = s.AliyunAccessKeyId;
            // Secret 不在这里读 —— 它必须走后台线程，见 LoadAliyunSecretAsync()
            SelectComboByTag(CmbAliyunRegion, s.AliyunConsoleRegion);
            SelectComboByTag(CmbAliyunSite, s.AliyunConsoleSite);
            TxtAliyunSwitchAgent.Text = s.AliyunConsoleSwitchAgent > 0
                ? s.AliyunConsoleSwitchAgent.ToString(CultureInfo.InvariantCulture) : string.Empty;
            ChkAliyunReuseCliConfig.IsChecked = s.AliyunReuseCliConfig;
            TxtAliyunBalanceThreshold.Text =
                s.AliyunBalanceAlertThreshold.ToString(CultureInfo.InvariantCulture);

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
            s.DeepSeekBalanceAlertThreshold = ParseThreshold(TxtDeepSeekThreshold.Text, 10);

            s.VolcengineEnabled = ChkVolcengineEnabled.IsChecked == true;
            s.VolcengineApiKey = TxtVolcengineKey.Text.Trim();
            s.VolcengineEndpoint = TxtVolcengineEndpoint.Text.Trim();
            s.VolcengineModel = TxtVolcengineModel.Text.Trim();

            s.KimiEnabled = ChkKimiEnabled.IsChecked == true;
            s.KimiApiKey = TxtKimiKey.Text.Trim();
            s.KimiEndpoint = TxtKimiEndpoint.Text.Trim();
            s.KimiModel = TxtKimiModel.Text.Trim();
            s.KimiBalanceAlertThreshold = ParseThreshold(TxtKimiThreshold.Text, 10);

            s.OpenRouterEnabled = ChkOpenRouterEnabled.IsChecked == true;
            s.OpenRouterApiKey = TxtOpenRouterKey.Text.Trim();
            s.OpenRouterEndpoint = TxtOpenRouterEndpoint.Text.Trim();
            s.OpenRouterBalanceAlertThreshold = ParseThreshold(TxtOpenRouterThreshold.Text, 5);

            s.GLMEnabled = ChkGLMEnabled.IsChecked == true;
            s.GLMApiKey = TxtGLMKey.Text.Trim();
            s.GLMEndpoint = TxtGLMEndpoint.Text.Trim();

            s.AliyunEnabled = ChkAliyunEnabled.IsChecked == true;
            s.AliyunCookie = TxtAliyunCookie.Text.Trim();
            s.AliyunAccessKeyId = TxtAliyunAkId.Text.Trim();
            s.AliyunConsoleRegion = SelectedTag(CmbAliyunRegion) ?? "cn-beijing";
            s.AliyunConsoleSite = SelectedTag(CmbAliyunSite) ?? "domestic";
            s.AliyunConsoleSwitchAgent =
                long.TryParse(TxtAliyunSwitchAgent.Text.Trim(), NumberStyles.Integer,
                    CultureInfo.InvariantCulture, out var switchAgent) ? switchAgent : 0;
            s.AliyunReuseCliConfig = ChkAliyunReuseCliConfig.IsChecked == true;
            s.AliyunBalanceAlertThreshold =
                decimal.TryParse(TxtAliyunBalanceThreshold.Text.Trim(), NumberStyles.Float,
                    CultureInfo.InvariantCulture, out var threshold) ? threshold : 10m;
            // AccessKey Secret 不写进 settings.json —— 见 BtnTestAliyunAK_Click

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
                else
                {
                    dot.Text = "●";
                    dot.Foreground = new SolidColorBrush(Color.FromRgb(156, 163, 175));
                    status.Text = LocalizationManager.Instance.StatusNotConnected;
                    account.Text = "";
                }
            }

            UpdateOne(ProviderType.OpenAI, TxtOpenAIStatusDot, TxtOpenAIStatus, TxtOpenAIAccount);
            UpdateOne(ProviderType.ClaudeCode, TxtClaudeStatusDot, TxtClaudeStatus, TxtClaudeAccount);
            UpdateOne(ProviderType.Gemini, TxtGeminiStatusDot, TxtGeminiStatus, TxtGeminiAccount);
            UpdateOne(ProviderType.DeepSeek, TxtDeepSeekStatusDot, TxtDeepSeekStatus, TxtDeepSeekAccount);
            UpdateOne(ProviderType.Volcengine, TxtVolcengineStatusDot, TxtVolcengineStatus, TxtVolcengineAccount);
            UpdateOne(ProviderType.Kimi, TxtKimiStatusDot, TxtKimiStatus, TxtKimiAccount);
            UpdateOne(ProviderType.OpenRouter, TxtOpenRouterStatusDot, TxtOpenRouterStatus, TxtOpenRouterAccount);
            UpdateOne(ProviderType.GLM, TxtGLMStatusDot, TxtGLMStatus, TxtGLMAccount);
            UpdateOne(ProviderType.AliyunBailian, TxtAliyunStatusDot, TxtAliyunStatus, TxtAliyunAccount);

            RenderCustomProvidersList();
        }

        private static decimal ParseThreshold(string? text, decimal fallback)
        {
            return decimal.TryParse(text?.Trim(), out var value) && value >= 0 ? value : fallback;
        }

        // ==================== Actions ====================

        private async void BtnTestOpenAI_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshOpenAIAsync();
            var q = RefreshManager.Instance.Quotas[ProviderType.OpenAI];
            var i18n = LocalizationManager.Instance;
            if (q.IsAuthorized)
                MessageBox.Show(i18n.IsChinese ? "OpenAI 授权连接成功！已检测到接口状态与可用模型。" : "OpenAI connection successful! API status and models detected.", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Information);
            else
                MessageBox.Show(i18n.IsChinese ? $"OpenAI 连接失败: {q.ErrorMessage}" : $"OpenAI connection failed: {q.ErrorMessage}", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        private async void BtnTestAnthropicKey_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshClaudeAsync();
            var q = RefreshManager.Instance.Quotas[ProviderType.ClaudeCode];
            var i18n = LocalizationManager.Instance;
            if (q.IsAuthorized)
                MessageBox.Show(i18n.IsChinese ? "Anthropic API Key 校验成功！" : "Anthropic API Key verified successfully!", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Information);
            else
                MessageBox.Show(i18n.IsChinese ? $"Anthropic 校验失败: {q.ErrorMessage}" : $"Anthropic verification failed: {q.ErrorMessage}", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        private void BtnImportClaudeLocal_Click(object sender, RoutedEventArgs e)
        {
            var i18n = LocalizationManager.Instance;
            if (RefreshManager.Instance.ImportClaudeFromLocal())
            {
                MessageBox.Show(i18n.IsChinese ? "成功从 ~/.claude.json 读取并同步本地 Claude CLI 配额！" : "Successfully read and synced local Claude CLI quota from ~/.claude.json!", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Information);
            }
            else
            {
                MessageBox.Show(i18n.IsChinese ? "未在本地找到 ~/.claude.json 配置文件，请先在终端运行 claude 进行登录。" : "Could not find ~/.claude.json locally. Please run claude login in terminal first.", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private async void BtnSaveClaudeToken_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshClaudeAsync();
            var i18n = LocalizationManager.Instance;
            MessageBox.Show(i18n.IsChinese ? "Claude Token 已保存并刷新！" : "Claude Token saved and refreshed!", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Information);
        }

        private async void BtnTestGeminiKey_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshGeminiAsync();
            var q = RefreshManager.Instance.Quotas[ProviderType.Gemini];
            var i18n = LocalizationManager.Instance;
            if (q.IsAuthorized)
                MessageBox.Show(i18n.IsChinese ? "Google AI Studio API 连接成功！" : "Google AI Studio API connected successfully!", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Information);
            else
                MessageBox.Show(i18n.IsChinese ? $"连接失败: {q.ErrorMessage}" : $"Connection failed: {q.ErrorMessage}", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        private async void BtnClearGeminiKey_Click(object sender, RoutedEventArgs e)
        {
            TxtGeminiKey.Text = "";
            SyncToSettings();
            await RefreshManager.Instance.RefreshGeminiAsync();
        }

        private async void BtnGeminiWebLogin_Click(object sender, RoutedEventArgs e)
        {
            var i18n = LocalizationManager.Instance;
            if (RefreshManager.Instance.ImportGeminiFromLocal())
            {
                TxtGeminiToken.Text = RefreshManager.Instance.Settings.GeminiToken;
                await RefreshManager.Instance.RefreshGeminiAsync();
                UpdateStatuses();
                var q = RefreshManager.Instance.Quotas[ProviderType.Gemini];
                MessageBox.Show(i18n.IsChinese ? $"Google 网站登录授权成功！\n已绑定账号: {q.AccountInfo ?? "Google 账号"}" : $"Google web login authorization successful!\nAccount: {q.AccountInfo ?? "Google Account"}", i18n.IsChinese ? "授权成功" : "Authorized", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            else
            {
                var result = MessageBox.Show(i18n.IsChinese ? "未检测到本地 Google 账号凭据。\n\n您可以使用 Antigravity CLI (agy) 完成 Google 登录，或在浏览器中打开 Google 授权页面。\n\n是否立即在浏览器中打开授权页面？" : "No local Google credentials found.\n\nYou can login using Antigravity CLI (agy) or open Google authorization page in browser.\n\nOpen authorization page in browser now?", i18n.AlertNotice, MessageBoxButton.YesNo, MessageBoxImage.Question);
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
            var i18n = LocalizationManager.Instance;
            if (RefreshManager.Instance.ImportGeminiFromLocal())
            {
                TxtGeminiToken.Text = RefreshManager.Instance.Settings.GeminiToken;
                await RefreshManager.Instance.RefreshGeminiAsync();
                UpdateStatuses();
                var q = RefreshManager.Instance.Quotas[ProviderType.Gemini];
                MessageBox.Show(i18n.IsChinese ? $"已成功从本地凭据 / Antigravity 读取 Google 凭证！\n当前绑定账号: {q.AccountInfo ?? "Google 账号"}" : $"Successfully read Google credentials from local config / Antigravity!\nAccount: {q.AccountInfo ?? "Google Account"}", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Information);
            }
            else
            {
                MessageBox.Show(i18n.IsChinese ? "未检测到本地 Google 凭证。\n请先运行 `agy` 登录 Google 账号，或使用上方 API Key 方式。" : "No local Google credentials detected.\nPlease run `agy` to login Google account, or use API Key above.", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private async void BtnSaveGeminiToken_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshGeminiAsync();
            var i18n = LocalizationManager.Instance;
            MessageBox.Show(i18n.IsChinese ? "Gemini Token 已保存！" : "Gemini Token saved!", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Information);
        }

        private async void BtnTestDeepSeek_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshDeepSeekAsync();
            var q = RefreshManager.Instance.Quotas[ProviderType.DeepSeek];
            var i18n = LocalizationManager.Instance;
            if (q.IsAuthorized)
                MessageBox.Show(i18n.IsChinese ? $"DeepSeek 连接成功！{q.AccountInfo}" : $"DeepSeek connected successfully! {q.AccountInfo}", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Information);
            else
                MessageBox.Show(i18n.IsChinese ? $"DeepSeek 连接失败: {q.ErrorMessage}" : $"DeepSeek connection failed: {q.ErrorMessage}", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        private async void BtnTestVolcengine_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshVolcengineAsync();
            var q = RefreshManager.Instance.Quotas[ProviderType.Volcengine];
            var i18n = LocalizationManager.Instance;
            if (q.IsAuthorized)
                MessageBox.Show(i18n.IsChinese ? "火山方舟接入点连接成功！" : "Volcengine Ark connected successfully!", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Information);
            else
                MessageBox.Show(i18n.IsChinese ? $"火山方舟连接失败: {q.ErrorMessage}" : $"Volcengine Ark connection failed: {q.ErrorMessage}", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        private async void BtnTestKimi_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshKimiAsync();
            var q = RefreshManager.Instance.Quotas[ProviderType.Kimi];
            var i18n = LocalizationManager.Instance;
            if (q.IsAuthorized)
                MessageBox.Show(i18n.IsChinese ? $"KIMI 连接成功！{q.AccountInfo}" : $"KIMI connected successfully! {q.AccountInfo}", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Information);
            else
                MessageBox.Show(i18n.IsChinese ? $"KIMI 连接失败: {q.ErrorMessage}" : $"KIMI connection failed: {q.ErrorMessage}", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        private async void BtnTestOpenRouter_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshOpenRouterAsync();
            var q = RefreshManager.Instance.Quotas[ProviderType.OpenRouter];
            var i18n = LocalizationManager.Instance;
            if (q.IsAuthorized)
                MessageBox.Show(i18n.IsChinese ? $"OpenRouter 连接成功！{q.AccountInfo}" : $"OpenRouter connected successfully! {q.AccountInfo}", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Information);
            else
                MessageBox.Show(i18n.IsChinese ? $"OpenRouter 连接失败: {q.ErrorMessage}" : $"OpenRouter connection failed: {q.ErrorMessage}", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        private async void BtnTestGLM_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshGLMAsync();
            var q = RefreshManager.Instance.Quotas[ProviderType.GLM];
            var i18n = LocalizationManager.Instance;
            if (q.IsAuthorized)
                MessageBox.Show(i18n.IsChinese ? "GLM 智谱 BigModel 授权连接成功！" : "GLM BigModel connected successfully!", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Information);
            else
                MessageBox.Show(i18n.IsChinese ? $"GLM 连接失败: {q.ErrorMessage}" : $"GLM connection failed: {q.ErrorMessage}", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        private static void SelectComboByTag(ComboBox combo, string? tag)
        {
            foreach (var item in combo.Items.OfType<ComboBoxItem>())
            {
                if ((item.Tag as string) == tag) { combo.SelectedItem = item; return; }
            }
            combo.SelectedIndex = 0;
        }

        private static string? SelectedTag(ComboBox combo)
            => (combo.SelectedItem as ComboBoxItem)?.Tag as string;

        private void BtnOpenRamConsole_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "https://ram.console.aliyun.com/manage/ak",
                    UseShellExecute = true
                });
            }
            catch { }
        }

        /// <summary>
        /// 从凭据管理器加载 AccessKey Secret。只在后台线程读，**读不到时不清空输入框**。
        ///
        /// 「读不到就清空」看着无害，实则是数据丢失的起点：清空 → 用户点保存 →
        /// 走 Delete 分支 → 凭据管理器里真实存在的 Secret 被抹掉。所以 Unavailable
        /// 下只改状态、不动内容，并由 BtnTestAliyunAK_Click 跳过删除。
        /// </summary>
        private async Task LoadAliyunSecretAsync()
        {
            var i18n = LocalizationManager.Instance;

            PwdAliyunAkSecret.IsEnabled = false;
            BtnTestAliyunAK.IsEnabled = false;
            PnlAliyunSecretWarning.Visibility = Visibility.Collapsed;
            TxtAliyunSecretHint.Text = i18n.HintAliyunSecretLoading;
            TxtAliyunSecretHint.Visibility = Visibility.Visible;

            var before = PwdAliyunAkSecret.Password;
            var result = await CredentialSecretStore.Instance.LookupAsync(SecretKey.AliyunAccessKeySecret);

            // 正常路径下输入框在读取期间是禁用的，这里是双保险
            var untouched = PwdAliyunAkSecret.Password == before;

            _aliyunSecretState = result.Kind;
            TxtAliyunSecretHint.Visibility = Visibility.Collapsed;
            PwdAliyunAkSecret.IsEnabled = true;
            BtnTestAliyunAK.IsEnabled = !_isSavingAliyunAk;

            switch (result.Kind)
            {
                case SecretLookupKind.Found:
                    if (untouched) PwdAliyunAkSecret.Password = result.Value ?? string.Empty;
                    break;
                case SecretLookupKind.Absent:
                    if (untouched) PwdAliyunAkSecret.Password = string.Empty;
                    break;
                default:
                    TxtAliyunSecretWarning.Text = i18n.WarnAliyunSecretUnreadable;
                    BtnRetryReadCredential.Content = i18n.BtnRetryReadCredential;
                    PnlAliyunSecretWarning.Visibility = Visibility.Visible;
                    Log.Error("lifecycle", "设置页读取 AccessKey Secret 失败，已进入保护模式：不清空、不删除");
                    break;
            }
        }

        private async void BtnRetryReadCredential_Click(object sender, RoutedEventArgs e)
        {
            try { await LoadAliyunSecretAsync(); }
            catch (Exception ex) { Log.Error("lifecycle", $"重试读取凭据失败: {ex.Message}"); }
        }

        /// <summary>
        /// 保存 AccessKey 并立即验证。
        ///
        /// Secret 只写凭据管理器 —— 写不进去就如实报错并中止，绝不降级成明文存进 settings.json。
        /// </summary>
        private async void BtnTestAliyunAK_Click(object sender, RoutedEventArgs e)
        {
            if (_isSavingAliyunAk) return;

            var i18n = LocalizationManager.Instance;
            var action = SecretSaveAction.Resolve(
                PwdAliyunAkSecret.Password,
                storeReadable: _aliyunSecretState != SecretLookupKind.Unavailable);

            _isSavingAliyunAk = true;
            BtnTestAliyunAK.IsEnabled = false;

            try
            {
                var noticePrefix = string.Empty;

                switch (action.Kind)
                {
                    case SecretSaveActionKind.Write:
                        // 语义 1：写不进去就如实报错并中止，其余明文字段一并不写，
                        // 避免「id 更新了、secret 还是老的」错配。
                        if (!await CredentialSecretStore.Instance.SetAsync(
                                SecretKey.AliyunAccessKeySecret, action.Value!))
                        {
                            MessageBox.Show(i18n.AlertAliyunSecretStoreFailed,
                                i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Warning);
                            return;
                        }
                        _aliyunSecretState = SecretLookupKind.Found;   // 刚写成功，说明凭据管理器通了
                        PnlAliyunSecretWarning.Visibility = Visibility.Collapsed;
                        break;

                    case SecretSaveActionKind.Delete:
                        // 语义 3：删除失败同样中止 —— 否则 akId 更新了而旧 secret 还在，
                        // 刷新会拿着用户以为已经删掉的凭证继续跑。
                        if (!await CredentialSecretStore.Instance.DeleteAsync(SecretKey.AliyunAccessKeySecret))
                        {
                            MessageBox.Show(i18n.AlertAliyunSecretDeleteFailed,
                                i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Warning);
                            return;
                        }
                        break;

                    default:
                        // 语义 2：读不到 + 输入框空，绝不删。其余明文设置照常保存，
                        // 提示拼进最终结果，避免和刷新结果抢同一个弹窗。
                        noticePrefix = i18n.AlertAliyunSecretKeptUnreadable + "\n\n";
                        Log.Notice("lifecycle", "设置页保存：凭据读不到且输入框为空，已跳过删除以保护现有 Secret");
                        break;
                }

                SyncToSettings();
                await RefreshManager.Instance.RefreshAliyunAsync();

                var q = RefreshManager.Instance.Quotas[ProviderType.AliyunBailian];
                if (q.IsAuthorized)
                {
                    var channel = string.IsNullOrEmpty(q.AccountInfo) ? string.Empty : "\n" + q.AccountInfo;
                    MessageBox.Show(noticePrefix + (i18n.IsChinese
                            ? "百炼额度读取成功！AccessKey 已保存到 Windows 凭据管理器。"
                            : "Bailian quota retrieved. The AccessKey is stored in Windows Credential Manager.") + channel,
                        i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Information);
                }
                else
                {
                    MessageBox.Show(noticePrefix + (i18n.IsChinese
                            ? $"百炼连接失败: {q.ErrorMessage}" : $"Bailian connection failed: {q.ErrorMessage}"),
                        i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Warning);
                }
            }
            finally
            {
                _isSavingAliyunAk = false;
                BtnTestAliyunAK.IsEnabled = true;
            }
        }

        private void BtnOpenAliyunCLI_Click(object sender, RoutedEventArgs e)
        {
            AliyunBailianService.OpenTerminalToLoginCLI();
        }

        private async void BtnTestAliyunCLI_Click(object sender, RoutedEventArgs e)
        {
            var i18n = LocalizationManager.Instance;
            try
            {
                var res = await AliyunBailianService.Instance.FetchViaCliAsync();
                MessageBox.Show(i18n.IsChinese ? "百炼 CLI 配额读取成功！已检测到 7天 与 5小时额度。" : "Bailian CLI quota retrieved successfully! 7-day and 5-hour quotas detected.", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Information);
                _ = RefreshManager.Instance.RefreshAliyunAsync();
            }
            catch (Exception ex)
            {
                MessageBox.Show(i18n.IsChinese ? $"百炼 CLI 读取失败: {ex.Message}" : $"Bailian CLI retrieval failed: {ex.Message}", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private async void BtnTestAliyunCookie_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            await RefreshManager.Instance.RefreshAliyunAsync();
            var q = RefreshManager.Instance.Quotas[ProviderType.AliyunBailian];
            var i18n = LocalizationManager.Instance;
            if (q.IsAuthorized)
                MessageBox.Show(i18n.IsChinese ? "百炼控制台 Cookie 授权连接成功！" : "Bailian console cookie connected successfully!", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Information);
            else
                MessageBox.Show(i18n.IsChinese ? $"百炼连接失败: {q.ErrorMessage}" : $"Bailian connection failed: {q.ErrorMessage}", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Warning);
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
                    Content = LocalizationManager.Instance.IsChinese ? "编辑" : "Edit",
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
                    Content = LocalizationManager.Instance.IsChinese ? "删除" : "Delete",
                    Padding = new Thickness(8, 3, 8, 3),
                    Background = Brushes.White,
                    BorderBrush = new SolidColorBrush(Color.FromRgb(209, 213, 219)),
                    Foreground = new SolidColorBrush(Color.FromRgb(239, 68, 68)),
                    FontSize = 11,
                    Cursor = System.Windows.Input.Cursors.Hand
                };
                btnDelete.Click += (s, e) =>
                {
                    var i18n = LocalizationManager.Instance;
                    if (MessageBox.Show(i18n.IsChinese ? $"确定要删除模型厂商「{cfg.Name}」吗？" : $"Are you sure you want to delete \"{cfg.Name}\"?", i18n.IsChinese ? "删除确认" : "Confirm Delete", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
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

        // ==================== Display Order ====================

        /// <summary>当前已启用厂商的显示顺序键（已按 ProviderOrder 排序，未列入的按默认顺序追加）。</summary>
        private List<string> BuildEnabledOrderKeys()
        {
            var settings = RefreshManager.Instance.Settings;
            var enabled = new List<string>();
            if (settings.OpenAIEnabled) enabled.Add(ProviderOrdering.KeyOf(ProviderType.OpenAI));
            if (settings.ClaudeEnabled) enabled.Add(ProviderOrdering.KeyOf(ProviderType.ClaudeCode));
            if (settings.GeminiEnabled) enabled.Add(ProviderOrdering.KeyOf(ProviderType.Gemini));
            if (settings.DeepSeekEnabled) enabled.Add(ProviderOrdering.KeyOf(ProviderType.DeepSeek));
            if (settings.VolcengineEnabled) enabled.Add(ProviderOrdering.KeyOf(ProviderType.Volcengine));
            if (settings.KimiEnabled) enabled.Add(ProviderOrdering.KeyOf(ProviderType.Kimi));
            if (settings.OpenRouterEnabled) enabled.Add(ProviderOrdering.KeyOf(ProviderType.OpenRouter));
            if (settings.GLMEnabled) enabled.Add(ProviderOrdering.KeyOf(ProviderType.GLM));
            if (settings.AliyunEnabled) enabled.Add(ProviderOrdering.KeyOf(ProviderType.AliyunBailian));
            enabled.AddRange(settings.CustomProviders.Where(c => c.IsEnabled).Select(c => ProviderOrdering.CustomKey(c.Id)));

            var order = settings.ProviderOrder;
            return enabled.OrderBy(k => ProviderOrdering.GetSortIndex(k, order)).ToList();
        }

        private void RenderOrderList()
        {
            PnlOrderList.Children.Clear();
            var i18n = LocalizationManager.Instance;
            var settings = RefreshManager.Instance.Settings;
            var keys = BuildEnabledOrderKeys();

            if (keys.Count == 0)
            {
                PnlOrderList.Children.Add(new TextBlock
                {
                    Text = i18n.NoEnabledProviders,
                    FontSize = 11,
                    Foreground = new SolidColorBrush(Color.FromRgb(107, 114, 128)),
                    Margin = new Thickness(0, 4, 0, 0)
                });
                return;
            }

            for (int i = 0; i < keys.Count; i++)
            {
                var key = keys[i];
                var index = i;
                var isFirst = i == 0;
                var isLast = i == keys.Count - 1;

                var row = new Border
                {
                    Background = new SolidColorBrush(Color.FromRgb(249, 250, 251)),
                    BorderBrush = new SolidColorBrush(Color.FromRgb(229, 231, 235)),
                    BorderThickness = new Thickness(1),
                    CornerRadius = new CornerRadius(8),
                    Padding = new Thickness(12, 8, 12, 8),
                    Margin = new Thickness(0, 0, 0, 6)
                };

                var dock = new DockPanel();

                var actions = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
                DockPanel.SetDock(actions, Dock.Right);

                var btnUp = new Button
                {
                    Content = $"↑ {i18n.MoveUp}",
                    Padding = new Thickness(8, 3, 8, 3),
                    Margin = new Thickness(0, 0, 6, 0),
                    Background = Brushes.White,
                    BorderBrush = new SolidColorBrush(Color.FromRgb(209, 213, 219)),
                    FontSize = 11,
                    IsEnabled = !isFirst,
                    Cursor = System.Windows.Input.Cursors.Hand
                };
                btnUp.Click += (s, e) => MoveProviderKey(index, -1);
                actions.Children.Add(btnUp);

                var btnDown = new Button
                {
                    Content = $"↓ {i18n.MoveDown}",
                    Padding = new Thickness(8, 3, 8, 3),
                    Background = Brushes.White,
                    BorderBrush = new SolidColorBrush(Color.FromRgb(209, 213, 219)),
                    FontSize = 11,
                    IsEnabled = !isLast,
                    Cursor = System.Windows.Input.Cursors.Hand
                };
                btnDown.Click += (s, e) => MoveProviderKey(index, +1);
                actions.Children.Add(btnDown);
                dock.Children.Add(actions);

                var nameRow = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };

                var builtinType = ProviderOrdering.ParseProviderType(key);
                var iconColor = builtinType.HasValue ? builtinType.Value.GetThemeColor() : Color.FromRgb(99, 102, 241);
                var iconBadge = new Border
                {
                    Width = 20,
                    Height = 20,
                    CornerRadius = new CornerRadius(5),
                    Background = new SolidColorBrush(Color.FromArgb(30, iconColor.R, iconColor.G, iconColor.B)),
                    Margin = new Thickness(0, 0, 8, 0),
                    VerticalAlignment = VerticalAlignment.Center
                };
                iconBadge.Child = new System.Windows.Shapes.Path
                {
                    Data = builtinType.HasValue
                        ? ProviderIcons.GetIconGeometry(builtinType.Value)
                        : ProviderIcons.GetTabIconGeometry(SettingsTab.Custom),
                    Fill = new SolidColorBrush(iconColor),
                    Stretch = Stretch.Uniform,
                    Width = 12,
                    Height = 12,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center
                };
                nameRow.Children.Add(iconBadge);

                var displayName = builtinType.HasValue ? builtinType.Value.GetDisplayName() : key;
                if (!builtinType.HasValue && ProviderOrdering.TryParseCustomKey(key, out var customId))
                {
                    displayName = settings.CustomProviders.FirstOrDefault(c => c.Id == customId)?.Name ?? key;
                }
                nameRow.Children.Add(new TextBlock
                {
                    Text = displayName,
                    FontWeight = FontWeights.Bold,
                    FontSize = 12,
                    VerticalAlignment = VerticalAlignment.Center
                });

                dock.Children.Add(nameRow);
                row.Child = dock;
                PnlOrderList.Children.Add(row);
            }
        }

        private void MoveProviderKey(int index, int delta)
        {
            var keys = BuildEnabledOrderKeys();
            int target = index + delta;
            if (target < 0 || target >= keys.Count)
            {
                return;
            }

            (keys[index], keys[target]) = (keys[target], keys[index]);
            RefreshManager.Instance.ApplyProviderOrder(keys);
            RenderOrderList();
        }

        private void BtnResetOrder_Click(object sender, RoutedEventArgs e)
        {
            RefreshManager.Instance.ApplyProviderOrder(new List<string>());
            RenderOrderList();
        }

        private void CmbPresets_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (CmbPresets.SelectedItem is ComboBoxItem item && item.Tag is DomesticProviderPreset preset)
            {
                TxtCustomName.Text = preset.LocalizedName;
                TxtCustomEndpoint.Text = preset.Endpoint;
                TxtCustomModel.Text = preset.DefaultModel;
                TxtCustomKey.Text = "";
                CmbCustomProtocol.SelectedIndex = preset.ApiProtocol switch
                {
                    ApiProtocol.OpenAIResponses => 1,
                    ApiProtocol.Anthropic => 2,
                    _ => 0
                };
                TxtCustomFormTitle.Text = LocalizationManager.Instance.IsChinese ? $"快速添加：{preset.Name}" : $"Quick Add: {preset.LocalizedName}";
                _editingCustomId = null;
                BdCustomForm.Visibility = Visibility.Visible;
            }
        }

        private void BtnAddCustomProvider_Click(object sender, RoutedEventArgs e)
        {
            _editingCustomId = null;
            TxtCustomFormTitle.Text = LocalizationManager.Instance.FormTitleAddProvider;
            TxtCustomName.Text = "";
            TxtCustomKey.Text = "";
            TxtCustomEndpoint.Text = "http://localhost:3000/v1";
            TxtCustomModel.Text = "";
            TxtCustomThreshold.Text = "";
            TxtCustomCookie.Text = "";
            CmbCustomProtocol.SelectedIndex = 0;
            BdCustomForm.Visibility = Visibility.Visible;
        }

        private void OpenEditCustomForm(CustomProviderConfig cfg)
        {
            _editingCustomId = cfg.Id;
            TxtCustomFormTitle.Text = LocalizationManager.Instance.IsChinese ? $"编辑厂商：{cfg.Name}" : $"Edit Provider: {cfg.Name}";
            TxtCustomName.Text = cfg.Name;
            TxtCustomKey.Text = cfg.ApiKey;
            TxtCustomEndpoint.Text = cfg.Endpoint;
            TxtCustomModel.Text = cfg.Model;
            TxtCustomThreshold.Text = cfg.BalanceAlertThreshold?.ToString("0.##") ?? "";
            TxtCustomCookie.Text = cfg.ConsoleCookie;
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

        /// <summary>自定义厂商余额阈值：留空表示使用默认值 (null)。</summary>
        private static decimal? ParseCustomThreshold(string? text)
        {
            if (string.IsNullOrWhiteSpace(text)) return null;
            return decimal.TryParse(text.Trim(), out var value) && value >= 0 ? value : null;
        }

        private void BtnSaveCustomForm_Click(object sender, RoutedEventArgs e)
        {
            var name = TxtCustomName.Text.Trim();
            if (string.IsNullOrEmpty(name))
            {
                var i18n = LocalizationManager.Instance;
                MessageBox.Show(i18n.IsChinese ? "请输入厂商名称" : "Please enter provider name", i18n.AlertNotice, MessageBoxButton.OK, MessageBoxImage.Warning);
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
                    existing.BalanceAlertThreshold = ParseCustomThreshold(TxtCustomThreshold.Text);
                    existing.ConsoleCookie = TxtCustomCookie.Text.Trim();
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
                    IsEnabled = true,
                    BalanceAlertThreshold = ParseCustomThreshold(TxtCustomThreshold.Text),
                    ConsoleCookie = TxtCustomCookie.Text.Trim()
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
            _ = RefreshManager.Instance.RefreshAllAsync(RefreshTrigger.Settings);
        }

        private void BtnClose_Click(object sender, RoutedEventArgs e)
        {
            SyncToSettings();
            Close();
        }
    }
}
