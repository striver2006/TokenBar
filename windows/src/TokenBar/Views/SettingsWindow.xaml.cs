using System;
using System.Windows;
using System.Windows.Controls;
using TokenBar.I18n;
using TokenBar.Models;
using TokenBar.Services;

namespace TokenBar.Views
{
    public partial class SettingsWindow : Window
    {
        public SettingsWindow()
        {
            InitializeComponent();
            LoadValues();
        }

        private void LoadValues()
        {
            var s = RefreshManager.Instance.Settings;
            CmbLanguage.SelectedIndex = (int)s.Language;
            TxtInterval.Text = s.RefreshIntervalMinutes.ToString();
            ChkHover.IsChecked = s.EnableHover;
            ChkLaunchAtLogin.IsChecked = s.LaunchAtLogin;

            ChkOpenAI.IsChecked = s.OpenAIEnabled;
            TxtOpenAIKey.Password = s.OpenAIApiKey;
            TxtOpenAIEndpoint.Text = s.OpenAIEndpoint;

            ChkClaude.IsChecked = s.ClaudeEnabled;
            TxtAnthropicKey.Password = s.AnthropicApiKey;
            TxtClaudeToken.Password = s.ClaudeToken;

            TxtAbout.Text = $"TokenBar v1.0.0 • {LocalizationManager.Instance.Subtitle}";
        }

        private void BtnSave_Click(object sender, RoutedEventArgs e)
        {
            var s = RefreshManager.Instance.Settings;
            s.Language = (AppLanguage)CmbLanguage.SelectedIndex;
            if (int.TryParse(TxtInterval.Text, out var interval)) s.RefreshIntervalMinutes = interval;
            s.EnableHover = ChkHover.IsChecked ?? true;
            s.LaunchAtLogin = ChkLaunchAtLogin.IsChecked ?? false;

            s.OpenAIEnabled = ChkOpenAI.IsChecked ?? false;
            s.OpenAIApiKey = TxtOpenAIKey.Password;
            s.OpenAIEndpoint = TxtOpenAIEndpoint.Text;

            s.ClaudeEnabled = ChkClaude.IsChecked ?? true;
            s.AnthropicApiKey = TxtAnthropicKey.Password;
            s.ClaudeToken = TxtClaudeToken.Password;

            RefreshManager.Instance.SaveSettings();
            MessageBox.Show("设置已保存 / Settings saved.", "TokenBar", MessageBoxButton.OK, MessageBoxImage.Information);
            Close();
        }

        private void BtnClose_Click(object sender, RoutedEventArgs e)
        {
            Close();
        }

        private void CmbLanguage_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (CmbLanguage.SelectedIndex >= 0)
            {
                LocalizationManager.Instance.CurrentLanguage = (AppLanguage)CmbLanguage.SelectedIndex;
                TxtAbout.Text = $"TokenBar v1.0.0 • {LocalizationManager.Instance.Subtitle}";
            }
        }
    }
}
