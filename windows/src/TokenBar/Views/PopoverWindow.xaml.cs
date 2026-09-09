using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using Brushes = System.Windows.Media.Brushes;
using Color = System.Windows.Media.Color;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using Button = System.Windows.Controls.Button;
using CheckBox = System.Windows.Controls.CheckBox;
using Orientation = System.Windows.Controls.Orientation;
using TokenBar.Helpers;
using TokenBar.I18n;
using TokenBar.Models;
using TokenBar.Services;
using TokenBar.Tray;

namespace TokenBar.Views
{
    public partial class PopoverWindow : Window
    {
        public PopoverWindow()
        {
            InitializeComponent();
            UpdateTexts();
            LocalizationManager.Instance.PropertyChanged += (s, e) => Dispatcher.Invoke(UpdateTexts);
            RefreshManager.Instance.OnQuotasUpdated += () => Dispatcher.Invoke(UpdateTexts);
            Closing += (s, e) =>
            {
                e.Cancel = true;
                Hide();
            };
        }

        private void UpdateTexts()
        {
            var i18n = LocalizationManager.Instance;
            TxtSubtitle.Text = i18n.Subtitle;
            BtnRefresh.Content = RefreshManager.Instance.IsRefreshing ? i18n.Refreshing : i18n.Refresh;
            BtnRefresh.IsEnabled = !RefreshManager.Instance.IsRefreshing;
            BtnSettings.ToolTip = i18n.OpenSettings;
            BtnClose.ToolTip = i18n.Close;

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
            var mgr = RefreshManager.Instance;
            var settings = mgr.Settings;
            var order = settings.ProviderOrder;

            // 按默认顺序收集可见卡片，再按用户配置的显示顺序（ProviderOrder）稳定排序；
            // 键未列入 ProviderOrder 的厂商排在已列出项之后并保持默认相对顺序
            var cards = new List<(string Key, UIElement Card)>();

            void TryAddBuiltIn(ProviderType type)
            {
                if (mgr.Quotas.TryGetValue(type, out var quota))
                {
                    cards.Add((ProviderOrdering.KeyOf(type),
                        CreateProviderCard(quota, () => OpenSettings(type.GetSettingsTab()))));
                }
            }

            if (settings.OpenAIEnabled) TryAddBuiltIn(ProviderType.OpenAI);
            if (settings.ClaudeEnabled) TryAddBuiltIn(ProviderType.ClaudeCode);
            if (settings.GeminiEnabled) TryAddBuiltIn(ProviderType.Gemini);
            if (settings.DeepSeekEnabled) TryAddBuiltIn(ProviderType.DeepSeek);
            if (settings.VolcengineEnabled) TryAddBuiltIn(ProviderType.Volcengine);
            if (settings.KimiEnabled) TryAddBuiltIn(ProviderType.Kimi);
            if (settings.OpenRouterEnabled) TryAddBuiltIn(ProviderType.OpenRouter);
            if (settings.GLMEnabled) TryAddBuiltIn(ProviderType.GLM);
            if (settings.AliyunEnabled) TryAddBuiltIn(ProviderType.AliyunBailian);

            foreach (var customConfig in settings.CustomProviders.Where(c => c.IsEnabled))
            {
                if (mgr.CustomQuotas.TryGetValue(customConfig.Id, out var customQuota))
                {
                    cards.Add((ProviderOrdering.CustomKey(customConfig.Id),
                        CreateCustomProviderCard(customConfig, customQuota, () => OpenSettings(SettingsTab.Custom))));
                }
            }

            foreach (var (_, card) in cards.OrderBy(c => ProviderOrdering.GetSortIndex(c.Key, order)))
            {
                PnlCards.Children.Add(card);
            }

            if (PnlCards.Children.Count == 0)
            {
                var emptyPanel = new StackPanel
                {
                    Margin = new Thickness(0, 30, 0, 30),
                    HorizontalAlignment = HorizontalAlignment.Center
                };
                emptyPanel.Children.Add(new TextBlock
                {
                    Text = "⚡",
                    FontSize = 24,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    Foreground = Brushes.Gray,
                    Margin = new Thickness(0, 0, 0, 8)
                });
                emptyPanel.Children.Add(new TextBlock
                {
                    Text = LocalizationManager.Instance.IsChinese ? "尚未启用任何模型厂商" : "No providers enabled",
                    FontSize = 12,
                    Foreground = Brushes.Gray,
                    HorizontalAlignment = HorizontalAlignment.Center
                });
                var btnConfig = new Button
                {
                    Content = LocalizationManager.Instance.Configure,
                    Margin = new Thickness(0, 10, 0, 0),
                    Padding = new Thickness(12, 4, 12, 4),
                    Background = new SolidColorBrush(Color.FromRgb(37, 99, 235)),
                    Foreground = Brushes.White,
                    Cursor = System.Windows.Input.Cursors.Hand
                };
                btnConfig.Click += (s, e) => OpenSettings(SettingsTab.General);
                emptyPanel.Children.Add(btnConfig);
                PnlCards.Children.Add(emptyPanel);
            }
        }

        private UIElement CreateProviderCard(ProviderQuota quota, Action onConfigure)
        {
            var card = new Border
            {
                Background = Brushes.White,
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(12, 10, 12, 10),
                Margin = new Thickness(0, 0, 0, 8),
                BorderBrush = new SolidColorBrush(Color.FromRgb(229, 231, 235)),
                BorderThickness = new Thickness(1)
            };

            var stack = new StackPanel();

            // Header row
            var headerGrid = new Grid();
            headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); // Icon
            headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); // Name
            headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); // Account
            headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); // Status dot

            // Icon badge
            var themeColor = quota.Provider.GetThemeColor();
            var iconBadge = new Border
            {
                Width = 22,
                Height = 22,
                CornerRadius = new CornerRadius(6),
                Background = new SolidColorBrush(Color.FromArgb(30, themeColor.R, themeColor.G, themeColor.B)),
                Margin = new Thickness(0, 0, 8, 0)
            };
            iconBadge.Child = new System.Windows.Shapes.Path
            {
                Data = ProviderIcons.GetIconGeometry(quota.Provider),
                Fill = new SolidColorBrush(themeColor),
                Stretch = Stretch.Uniform,
                Width = 13,
                Height = 13,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            };
            Grid.SetColumn(iconBadge, 0);
            headerGrid.Children.Add(iconBadge);

            // Name
            var nameBlock = new TextBlock
            {
                Text = quota.Provider.GetDisplayName(),
                FontWeight = FontWeights.Bold,
                FontSize = 12,
                Foreground = new SolidColorBrush(Color.FromRgb(17, 24, 39)),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 6, 0)
            };
            Grid.SetColumn(nameBlock, 1);
            headerGrid.Children.Add(nameBlock);

            // Account
            if (!string.IsNullOrEmpty(quota.AccountInfo))
            {
                var accBlock = new TextBlock
                {
                    Text = quota.AccountInfo,
                    FontSize = 10,
                    Foreground = new SolidColorBrush(Color.FromRgb(107, 114, 128)),
                    VerticalAlignment = VerticalAlignment.Center,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    MaxWidth = 100
                };
                Grid.SetColumn(accBlock, 2);
                headerGrid.Children.Add(accBlock);
            }

            // Status indicator
            var statusEllipse = new Ellipse
            {
                Width = 7,
                Height = 7,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(4, 0, 0, 0)
            };
            if (quota.IsLoading)
            {
                statusEllipse.Fill = new SolidColorBrush(Color.FromRgb(59, 130, 246)); // Blue loading
            }
            else if (quota.IsAuthorized)
            {
                statusEllipse.Fill = new SolidColorBrush(Color.FromRgb(34, 197, 94)); // Green
            }
            else
            {
                statusEllipse.Fill = new SolidColorBrush(Color.FromRgb(245, 158, 11)); // Orange
            }
            Grid.SetColumn(statusEllipse, 3);
            headerGrid.Children.Add(statusEllipse);

            stack.Children.Add(headerGrid);

            // Body
            if (!quota.IsAuthorized)
            {
                var errorDock = new DockPanel { Margin = new Thickness(0, 8, 0, 2) };
                var btnConfig = new Button
                {
                    Content = LocalizationManager.Instance.Configure,
                    Padding = new Thickness(8, 2, 8, 2),
                    FontSize = 11,
                    Background = new SolidColorBrush(Color.FromRgb(37, 99, 235)),
                    Foreground = Brushes.White,
                    Cursor = System.Windows.Input.Cursors.Hand,
                    HorizontalAlignment = HorizontalAlignment.Right
                };
                btnConfig.Click += (s, e) => onConfigure();
                DockPanel.SetDock(btnConfig, Dock.Right);
                errorDock.Children.Add(btnConfig);

                var msgBlock = new TextBlock
                {
                    Text = quota.ErrorMessage ?? LocalizationManager.Instance.NotAuthorized,
                    FontSize = 11,
                    Foreground = new SolidColorBrush(Color.FromRgb(239, 68, 68)),
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    VerticalAlignment = VerticalAlignment.Center
                };
                errorDock.Children.Add(msgBlock);
                stack.Children.Add(errorDock);
            }
            else if (quota.FiveHourWindow == null && quota.WeeklyWindow == null && quota.BalanceWindow == null)
            {
                var syncBlock = new TextBlock
                {
                    Text = quota.ErrorMessage ?? LocalizationManager.Instance.SyncingData,
                    FontSize = 11,
                    Foreground = new SolidColorBrush(Color.FromRgb(107, 114, 128)),
                    Margin = new Thickness(0, 6, 0, 2)
                };
                stack.Children.Add(syncBlock);
            }
            else
            {
                UIElement CreateSeparator() => new Border
                {
                    Height = 1,
                    Background = new SolidColorBrush(Color.FromRgb(243, 244, 246)),
                    Margin = new Thickness(0, 6, 0, 6)
                };

                // 5小时窗口
                if (quota.FiveHourWindow != null)
                {
                    stack.Children.Add(CreateWindowQuotaRow(quota.FiveHourWindow, LocalizationManager.Instance.FiveHourWindow));
                }

                if (quota.FiveHourWindow != null && quota.WeeklyWindow != null && quota.BalanceWindow == null)
                {
                    stack.Children.Add(CreateSeparator());
                }

                // 账户余额（与时间窗口并存，例如百炼的账户现金余额）
                if (quota.BalanceWindow != null)
                {
                    if (quota.FiveHourWindow != null)
                    {
                        stack.Children.Add(CreateSeparator());
                    }
                    stack.Children.Add(CreateWindowQuotaRow(quota.BalanceWindow, LocalizationManager.Instance.BalanceBadge));
                }

                if (quota.BalanceWindow != null && quota.WeeklyWindow != null)
                {
                    stack.Children.Add(CreateSeparator());
                }

                // 每周/周期窗口
                if (quota.WeeklyWindow != null)
                {
                    stack.Children.Add(CreateWindowQuotaRow(quota.WeeklyWindow, LocalizationManager.Instance.WeeklyWindow));
                }
            }

            card.Child = stack;
            return card;
        }

        private UIElement CreateCustomProviderCard(CustomProviderConfig config, CustomProviderQuota quota, Action onConfigure)
        {
            var card = new Border
            {
                Background = Brushes.White,
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(12, 10, 12, 10),
                Margin = new Thickness(0, 0, 0, 8),
                BorderBrush = new SolidColorBrush(Color.FromRgb(229, 231, 235)),
                BorderThickness = new Thickness(1)
            };

            var stack = new StackPanel();

            var headerGrid = new Grid();
            headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var iconBadge = new Border
            {
                Width = 22,
                Height = 22,
                CornerRadius = new CornerRadius(6),
                Background = new SolidColorBrush(Color.FromArgb(30, 99, 102, 241)), // Indigo
                Margin = new Thickness(0, 0, 8, 0)
            };
            var displayName = config.Name.Length > 0 ? config.Name : LocalizationManager.Instance.FallbackCustomProviderName;
            iconBadge.Child = new TextBlock
            {
                Text = displayName.Substring(0, 1),
                FontSize = 11,
                FontWeight = FontWeights.Bold,
                Foreground = new SolidColorBrush(Color.FromRgb(99, 102, 241)),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            };
            Grid.SetColumn(iconBadge, 0);
            headerGrid.Children.Add(iconBadge);

            var nameBlock = new TextBlock
            {
                Text = displayName,
                FontWeight = FontWeights.Bold,
                FontSize = 12,
                Foreground = new SolidColorBrush(Color.FromRgb(17, 24, 39)),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 6, 0)
            };
            Grid.SetColumn(nameBlock, 1);
            headerGrid.Children.Add(nameBlock);

            if (!string.IsNullOrEmpty(quota.AccountInfo))
            {
                var accBlock = new TextBlock
                {
                    Text = quota.AccountInfo,
                    FontSize = 10,
                    Foreground = new SolidColorBrush(Color.FromRgb(107, 114, 128)),
                    VerticalAlignment = VerticalAlignment.Center,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    MaxWidth = 100
                };
                Grid.SetColumn(accBlock, 2);
                headerGrid.Children.Add(accBlock);
            }

            var statusEllipse = new Ellipse
            {
                Width = 7,
                Height = 7,
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(4, 0, 0, 0),
                Fill = quota.IsAuthorized ? new SolidColorBrush(Color.FromRgb(34, 197, 94)) : new SolidColorBrush(Color.FromRgb(245, 158, 11))
            };
            Grid.SetColumn(statusEllipse, 3);
            headerGrid.Children.Add(statusEllipse);

            stack.Children.Add(headerGrid);

            if (!quota.IsAuthorized)
            {
                var errorDock = new DockPanel { Margin = new Thickness(0, 8, 0, 2) };
                var btnConfig = new Button
                {
                    Content = LocalizationManager.Instance.Configure,
                    Padding = new Thickness(8, 2, 8, 2),
                    FontSize = 11,
                    Background = new SolidColorBrush(Color.FromRgb(37, 99, 235)),
                    Foreground = Brushes.White,
                    Cursor = System.Windows.Input.Cursors.Hand,
                    HorizontalAlignment = HorizontalAlignment.Right
                };
                btnConfig.Click += (s, e) => onConfigure();
                DockPanel.SetDock(btnConfig, Dock.Right);
                errorDock.Children.Add(btnConfig);

                var msgBlock = new TextBlock
                {
                    Text = quota.ErrorMessage ?? LocalizationManager.Instance.NotAuthorized,
                    FontSize = 11,
                    Foreground = new SolidColorBrush(Color.FromRgb(239, 68, 68)),
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    VerticalAlignment = VerticalAlignment.Center
                };
                errorDock.Children.Add(msgBlock);
                stack.Children.Add(errorDock);
            }
            else
            {
                if (quota.PrimaryWindow != null)
                {
                    stack.Children.Add(CreateWindowQuotaRow(quota.PrimaryWindow, LocalizationManager.Instance.QuotaBadge));
                }
                if (quota.PrimaryWindow != null && quota.SecondaryWindow != null)
                {
                    var sep = new Border
                    {
                        Height = 1,
                        Background = new SolidColorBrush(Color.FromRgb(243, 244, 246)),
                        Margin = new Thickness(0, 6, 0, 6)
                    };
                    stack.Children.Add(sep);
                }
                if (quota.SecondaryWindow != null)
                {
                    stack.Children.Add(CreateWindowQuotaRow(quota.SecondaryWindow, LocalizationManager.Instance.RateBadge));
                }
            }

            card.Child = stack;
            return card;
        }

        private UIElement CreateWindowQuotaRow(TokenWindow window, string badgeText)
        {
            var isBalance = window.Kind == TokenWindowKind.Balance;
            if (isBalance)
            {
                badgeText = LocalizationManager.Instance.BalanceBadge;
            }

            var rowStack = new StackPanel { Margin = new Thickness(0, 6, 0, 2) };

            // Row 1: Badge, Title & Remaining %
            var topGrid = new Grid();
            topGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            topGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            topGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var badge = new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(20, 0, 0, 0)),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(5, 1, 5, 1),
                Margin = new Thickness(0, 0, 6, 0)
            };
            badge.Child = new TextBlock
            {
                Text = badgeText,
                FontSize = 9,
                FontWeight = FontWeights.Bold,
                Foreground = new SolidColorBrush(Color.FromRgb(55, 65, 81))
            };
            Grid.SetColumn(badge, 0);
            topGrid.Children.Add(badge);

            var titleBlock = new TextBlock
            {
                Text = window.LocalizedTitle,
                FontSize = 11,
                FontWeight = FontWeights.Medium,
                Foreground = new SolidColorBrush(Color.FromRgb(17, 24, 39)),
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis
            };
            Grid.SetColumn(titleBlock, 1);
            topGrid.Children.Add(titleBlock);

            if (isBalance)
            {
                // 余额窗口：直接显示金额，而不是"剩余 X%"
                var balanceBlock = new TextBlock
                {
                    Text = window.BalanceFormatted,
                    FontSize = 13,
                    FontWeight = FontWeights.Bold,
                    Foreground = window.StatusBrush,
                    VerticalAlignment = VerticalAlignment.Bottom
                };
                Grid.SetColumn(balanceBlock, 2);
                topGrid.Children.Add(balanceBlock);
            }
            else
            {
                var pctStack = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
                pctStack.Children.Add(new TextBlock
                {
                    Text = $"{LocalizationManager.Instance.Remaining} ",
                    FontSize = 10,
                    Foreground = new SolidColorBrush(Color.FromRgb(107, 114, 128)),
                    VerticalAlignment = VerticalAlignment.Bottom
                });
                pctStack.Children.Add(new TextBlock
                {
                    Text = $"{window.RemainingPercentage:0}%",
                    FontSize = 13,
                    FontWeight = FontWeights.Bold,
                    Foreground = window.StatusBrush,
                    VerticalAlignment = VerticalAlignment.Bottom
                });
                Grid.SetColumn(pctStack, 2);
                topGrid.Children.Add(pctStack);
            }

            rowStack.Children.Add(topGrid);

            if (isBalance)
            {
                // 余额窗口没有进度条与时间窗口概念：展示较上次变化与预计可用天数
                var balanceDock = new DockPanel();

                var deltaText = window.BalanceDeltaFormatted;
                var deltaBlock = new TextBlock
                {
                    Text = string.IsNullOrEmpty(deltaText)
                        ? ""
                        : string.Format(LocalizationManager.Instance.BalanceVsLast, deltaText),
                    FontSize = 9,
                    Foreground = new SolidColorBrush(Color.FromRgb(107, 114, 128))
                };
                balanceDock.Children.Add(deltaBlock);

                var forecastBlock = new TextBlock
                {
                    Text = window.ForecastDays.HasValue
                        ? string.Format(LocalizationManager.Instance.ForecastDays, window.ForecastDays.Value)
                        : LocalizationManager.Instance.ForecastCollecting,
                    FontSize = 9,
                    FontWeight = FontWeights.Medium,
                    Foreground = new SolidColorBrush(Color.FromRgb(107, 114, 128)),
                    HorizontalAlignment = HorizontalAlignment.Right
                };
                DockPanel.SetDock(forecastBlock, Dock.Right);
                balanceDock.Children.Add(forecastBlock);

                rowStack.Children.Add(balanceDock);

                return rowStack;
            }

            // Row 2: Progress Bar
            var barGrid = new Grid { Height = 6, Margin = new Thickness(0, 4, 0, 4) };
            var remPct = Math.Clamp(window.RemainingPercentage, 0.0, 100.0);
            var usedPct = Math.Clamp(100.0 - remPct, 0.0, 100.0);

            barGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(1, remPct), GridUnitType.Star) });
            barGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(1, usedPct), GridUnitType.Star) });

            var bgTrack = new Border
            {
                Background = new SolidColorBrush(Color.FromRgb(229, 231, 235)),
                CornerRadius = new CornerRadius(3)
            };
            Grid.SetColumnSpan(bgTrack, 2);
            barGrid.Children.Add(bgTrack);

            var fillBar = new Border
            {
                Background = window.StatusBrush,
                CornerRadius = new CornerRadius(3)
            };
            Grid.SetColumn(fillBar, 0);
            barGrid.Children.Add(fillBar);

            rowStack.Children.Add(barGrid);

            // Row 3: Time Range & Reset Countdown
            var bottomDock = new DockPanel();
            var timeRangeBlock = new TextBlock
            {
                Text = window.TimeRangeFormatted,
                FontSize = 9,
                Foreground = new SolidColorBrush(Color.FromRgb(107, 114, 128))
            };
            bottomDock.Children.Add(timeRangeBlock);

            var countdownBlock = new TextBlock
            {
                Text = window.TimeRemainingFormatted,
                FontSize = 9,
                FontWeight = FontWeights.Medium,
                Foreground = window.IsExpired ? new SolidColorBrush(Color.FromRgb(239, 68, 68)) : new SolidColorBrush(Color.FromRgb(107, 114, 128)),
                HorizontalAlignment = HorizontalAlignment.Right
            };
            DockPanel.SetDock(countdownBlock, Dock.Right);
            bottomDock.Children.Add(countdownBlock);

            rowStack.Children.Add(bottomDock);

            return rowStack;
        }

        public void ShowNearTray(bool activate = true)
        {
            var workArea = SystemParameters.WorkArea;
            Left = workArea.Right - Width - 10;
            Top = workArea.Bottom - Height - 10;

            // 悬停预览时不能抢焦点，否则会打断用户当前的操作
            ShowActivated = activate;
            Show();
            if (activate)
            {
                Activate();
            }
        }

        private async void BtnRefresh_Click(object sender, RoutedEventArgs e)
        {
            await RefreshManager.Instance.RefreshAllAsync(RefreshTrigger.Manual);
        }

        private void BtnSettings_Click(object sender, RoutedEventArgs e)
        {
            OpenSettings(SettingsTab.General);
        }

        private void OpenSettings(SettingsTab tab)
        {
            Hide();
            if (TrayIconManager.Instance != null)
            {
                TrayIconManager.Instance.OpenSettings(tab);
            }
            else
            {
                var win = new SettingsWindow(tab);
                win.Show();
                win.Activate();
            }
        }

        private void BtnClose_Click(object sender, RoutedEventArgs e)
        {
            Hide();
        }
    }
}
