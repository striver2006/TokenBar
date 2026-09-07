using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using TokenBar.I18n;
using TokenBar.Services;

namespace TokenBar.Views
{
    public partial class PopoverWindow : Window
    {
        public PopoverWindow()
        {
            InitializeComponent();
            UpdateTexts();
            RefreshManager.Instance.OnQuotasUpdated += () => Dispatcher.Invoke(UpdateTexts);
        }

        private void UpdateTexts()
        {
            var i18n = LocalizationManager.Instance;
            TxtSubtitle.Text = i18n.Subtitle;
            BtnRefresh.Content = RefreshManager.Instance.IsRefreshing ? i18n.Refreshing : i18n.Refresh;

            if (RefreshManager.Instance.LastRefreshDate.HasValue)
            {
                TxtFooter.Text = $"{i18n.UpdatedAt}{RefreshManager.Instance.LastRefreshDate.Value:HH:mm:ss}";
            }
            else
            {
                TxtFooter.Text = i18n.Ready;
            }

            RenderCards();
        }

        private void RenderCards()
        {
            PnlCards.Children.Clear();

            // Sample provider card preview
            var card = new Border
            {
                Background = Brushes.White,
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(10),
                Margin = new Thickness(0, 0, 0, 8),
                BorderBrush = new SolidColorBrush(Color.FromRgb(229, 231, 235)),
                BorderThickness = new Thickness(1)
            };

            var stack = new StackPanel();
            var titleRow = new DockPanel();
            var name = new TextBlock { Text = "Anthropic (Claude)", FontWeight = FontWeights.Bold, FontSize = 12 };
            var status = new TextBlock { Text = "●", Foreground = Brushes.Green, HorizontalAlignment = HorizontalAlignment.Right };
            titleRow.Children.Add(status);
            DockPanel.SetDock(status, Dock.Right);
            titleRow.Children.Add(name);

            var desc = new TextBlock
            {
                Text = $"{LocalizationManager.Instance.FiveHourWindow}: 100% {LocalizationManager.Instance.Remaining}",
                FontSize = 11,
                Foreground = Brushes.Gray,
                Margin = new Thickness(0, 4, 0, 0)
            };

            stack.Children.Add(titleRow);
            stack.Children.Add(desc);
            card.Child = stack;

            PnlCards.Children.Add(card);
        }

        public void ShowNearTray()
        {
            var screenWidth = SystemParameters.PrimaryScreenWidth;
            var screenHeight = SystemParameters.PrimaryScreenHeight;
            var workArea = SystemParameters.WorkArea;

            Left = workArea.Right - Width - 10;
            Top = workArea.Bottom - Height - 10;

            Show();
            Activate();
        }

        private async void BtnRefresh_Click(object sender, RoutedEventArgs e)
        {
            await RefreshManager.Instance.RefreshAllAsync();
        }

        private void BtnSettings_Click(object sender, RoutedEventArgs e)
        {
            Hide();
            var win = new SettingsWindow();
            win.Show();
        }

        private void BtnClose_Click(object sender, RoutedEventArgs e)
        {
            Hide();
        }
    }
}
