using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
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
        // 浮窗是单实例复用的：普通 Close 只隐藏，只有 ForceClose（退出应用）才真正关闭
        private bool _allowClose;
        // 隐藏期间收到配额通知不重建视觉树（一轮刷新 ≥20 次通知），记脏等显示时补一次
        private bool _renderDirty;

        public PopoverWindow()
        {
            InitializeComponent();
            UpdateTexts();
            LocalizationManager.Instance.PropertyChanged += OnLanguageChanged;
            RefreshManager.Instance.OnQuotasUpdated += OnQuotasUpdated;
            IsVisibleChanged += OnWindowIsVisibleChanged;
            Closing += OnClosingHideInstead;
            Closed += OnClosedUnsubscribe;
        }

        private void OnLanguageChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
            => Dispatcher.Invoke(UpdateTexts);

        private void OnQuotasUpdated()
            => Dispatcher.Invoke(UpdateTexts);

        private void OnClosingHideInstead(object? sender, System.ComponentModel.CancelEventArgs e)
        {
            if (_allowClose) return;
            e.Cancel = true;
            Hide();
        }

        private void OnClosedUnsubscribe(object? sender, EventArgs e)
        {
            LocalizationManager.Instance.PropertyChanged -= OnLanguageChanged;
            RefreshManager.Instance.OnQuotasUpdated -= OnQuotasUpdated;
            IsVisibleChanged -= OnWindowIsVisibleChanged;
            Closing -= OnClosingHideInstead;
            Closed -= OnClosedUnsubscribe;
        }

        /// <summary>应用退出时真正关闭窗口（普通 Close 会被拦成 Hide）。</summary>
        public void ForceClose()
        {
            _allowClose = true;
            Close();
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

            if (IsVisible)
            {
                RenderCards();
                _renderDirty = false;
            }
            else
            {
                _renderDirty = true;
            }
        }

        private void OnWindowIsVisibleChanged(object sender, DependencyPropertyChangedEventArgs e)
        {
            if (IsVisible && _renderDirty)
            {
                _renderDirty = false;
                UpdateTexts();
            }
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

        /// <summary>
        /// 卡片窗口槽位：槽位窗口（null 表示不渲染该行）、默认角标文本、
        /// 以及本行渲染前是否画分隔线的判定（仅在本行确实渲染时求值）。
        /// </summary>
        private sealed record CardRow(TokenWindow? Window, string Label, Func<bool>? SepBefore);

        /// <summary>内置/自定义厂商卡片的共享入参，两类卡片的全部差异都在这里表达。</summary>
        private sealed record CardSpec(
            Geometry? IconGeometry,      // 非 null 时角标画官方 glyph；null 时退回名字首字母
            Color IconColor,             // 角标底色（alpha 30）与 glyph/首字母前景色
            string? IconFallbackLetter,  // 自定义厂商无预设 Logo 时的首字母（内置厂商恒有 Geometry）
            string DisplayName,
            string? AccountInfo,
            Color StatusColor,           // 头部状态点颜色（内置有蓝色 loading 态，自定义没有）
            bool IsAuthorized,
            bool HadRefreshError,
            string? ErrorMessage,
            string? SyncingMessage,      // 已授权但无任何窗口数据时的提示；null 表示无此分支（自定义厂商）
            IReadOnlyList<CardRow> Rows,
            string? CacheNote,           // 数据读自本地缓存时的来源小字（Claude）；null 表示实时数据
            Action OnConfigure);

        private UIElement CreateProviderCard(ProviderQuota quota, Action onConfigure)
        {
            var i18n = LocalizationManager.Instance;
            var themeColor = quota.Provider.GetThemeColor();
            // 状态点：加载中蓝色 > 已授权绿色 > 未授权橙色
            var statusColor = quota.IsLoading ? Color.FromRgb(59, 130, 246)
                : quota.IsAuthorized ? Color.FromRgb(34, 197, 94)
                : Color.FromRgb(245, 158, 11);

            return CreateQuotaCard(new CardSpec(
                ProviderIcons.GetIconGeometry(quota.Provider),
                themeColor,
                null,
                quota.Provider.GetDisplayName(),
                quota.AccountInfo,
                statusColor,
                quota.IsAuthorized,
                quota.HadRefreshError,
                quota.ErrorMessage,
                quota.ErrorMessage ?? i18n.SyncingData,
                new[]
                {
                    // 5小时窗口
                    new CardRow(quota.FiveHourWindow, i18n.FiveHourWindow, null),
                    // 账户余额（与时间窗口并存，例如百炼的账户现金余额）
                    new CardRow(quota.BalanceWindow, i18n.BalanceBadge, () => quota.FiveHourWindow != null),
                    // 每周/周期窗口
                    new CardRow(quota.WeeklyWindow, i18n.WeeklyWindow,
                        () => (quota.FiveHourWindow != null && quota.BalanceWindow == null) || quota.BalanceWindow != null),
                    // 按模型圈定的周额度（如 Fable）
                    new CardRow(quota.ScopedWeeklyWindow, i18n.WeeklyWindow, () => quota.WeeklyWindow != null),
                },
                quota.LocalCacheNote(DateTime.Now),
                onConfigure));
        }

        private UIElement CreateCustomProviderCard(CustomProviderConfig config, CustomProviderQuota quota, Action onConfigure)
        {
            var i18n = LocalizationManager.Instance;
            var displayName = config.Name.Length > 0 ? config.Name : i18n.FallbackCustomProviderName;
            var presetLogo = ProviderIcons.GetPresetLogo(displayName);
            var badgeColor = presetLogo?.Color ?? Color.FromRgb(99, 102, 241); // Indigo

            return CreateQuotaCard(new CardSpec(
                // 命中品牌预设:渲染官方 Logo(与内置厂商卡片同款 13x13 单色 glyph)
                presetLogo?.Geometry,
                badgeColor,
                displayName.Substring(0, 1),
                displayName,
                quota.AccountInfo,
                // 状态点：已授权绿色 > 未授权橙色（自定义卡片没有 loading 蓝色态）
                quota.IsAuthorized ? Color.FromRgb(34, 197, 94) : Color.FromRgb(245, 158, 11),
                quota.IsAuthorized,
                quota.HadRefreshError,
                quota.ErrorMessage,
                null,
                new[]
                {
                    new CardRow(quota.PrimaryWindow, i18n.QuotaBadge, null),
                    new CardRow(quota.SecondaryWindow, i18n.RateBadge, () => quota.PrimaryWindow != null),
                },
                null,
                onConfigure));
        }

        /// <summary>
        /// 共享卡片构造器：Border 容器 + header（图标角标/名称/账号/状态点）
        /// + body 分支（去配置 / 刷新失败重试 / 同步中 / 窗口额度行 + 刷新失败小字提示）。
        /// </summary>
        private UIElement CreateQuotaCard(CardSpec spec)
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
            var iconBadge = new Border
            {
                Width = 22,
                Height = 22,
                CornerRadius = new CornerRadius(6),
                Background = new SolidColorBrush(Color.FromArgb(30, spec.IconColor.R, spec.IconColor.G, spec.IconColor.B)),
                Margin = new Thickness(0, 0, 8, 0)
            };
            if (spec.IconGeometry != null)
            {
                iconBadge.Child = new System.Windows.Shapes.Path
                {
                    Data = spec.IconGeometry,
                    Fill = new SolidColorBrush(spec.IconColor),
                    Stretch = Stretch.Uniform,
                    Width = 13,
                    Height = 13,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center
                };
            }
            else
            {
                iconBadge.Child = new TextBlock
                {
                    Text = spec.IconFallbackLetter,
                    FontSize = 11,
                    FontWeight = FontWeights.Bold,
                    Foreground = new SolidColorBrush(spec.IconColor),
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center
                };
            }
            Grid.SetColumn(iconBadge, 0);
            headerGrid.Children.Add(iconBadge);

            // Name
            var nameBlock = new TextBlock
            {
                Text = spec.DisplayName,
                FontWeight = FontWeights.Bold,
                FontSize = 12,
                Foreground = new SolidColorBrush(Color.FromRgb(17, 24, 39)),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 6, 0)
            };
            Grid.SetColumn(nameBlock, 1);
            headerGrid.Children.Add(nameBlock);

            // Account
            if (!string.IsNullOrEmpty(spec.AccountInfo))
            {
                var accBlock = new TextBlock
                {
                    Text = spec.AccountInfo,
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
                Margin = new Thickness(4, 0, 0, 0),
                Fill = new SolidColorBrush(spec.StatusColor)
            };
            Grid.SetColumn(statusEllipse, 3);
            headerGrid.Children.Add(statusEllipse);

            stack.Children.Add(headerGrid);

            // Body
            bool hasWindowData = spec.Rows.Any(r => r.Window != null);

            if (!spec.IsAuthorized && !spec.HadRefreshError)
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
                btnConfig.Click += (s, e) => spec.OnConfigure();
                DockPanel.SetDock(btnConfig, Dock.Right);
                errorDock.Children.Add(btnConfig);

                var msgBlock = new TextBlock
                {
                    Text = spec.ErrorMessage ?? LocalizationManager.Instance.NotAuthorized,
                    FontSize = 11,
                    Foreground = new SolidColorBrush(Color.FromRgb(239, 68, 68)),
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    VerticalAlignment = VerticalAlignment.Center
                };
                errorDock.Children.Add(msgBlock);
                stack.Children.Add(errorDock);
            }
            else if (spec.HadRefreshError && !hasWindowData)
            {
                // 已配置但刷新失败（多为开机网络未就绪）：显示错误 + 「重试」，而不是误导性的「去配置」
                AddRefreshErrorRow(stack, spec.ErrorMessage);
            }
            else if (!hasWindowData && spec.SyncingMessage != null)
            {
                var syncBlock = new TextBlock
                {
                    Text = spec.SyncingMessage,
                    FontSize = 11,
                    Foreground = new SolidColorBrush(Color.FromRgb(107, 114, 128)),
                    Margin = new Thickness(0, 6, 0, 2)
                };
                stack.Children.Add(syncBlock);
            }
            else
            {
                foreach (var row in spec.Rows)
                {
                    if (row.Window == null) continue;
                    if (row.SepBefore != null && row.SepBefore())
                    {
                        stack.Children.Add(new Border
                        {
                            Height = 1,
                            Background = new SolidColorBrush(Color.FromRgb(243, 244, 246)),
                            Margin = new Thickness(0, 6, 0, 6)
                        });
                    }
                    stack.Children.Add(CreateWindowQuotaRow(row.Window, row.Label));
                }

                if (spec.CacheNote != null)
                {
                    AddCacheNote(stack, spec.CacheNote);
                }

                if (spec.HadRefreshError)
                {
                    // 本轮刷新失败但旧数据仍可参考：末尾叠一行小字提示，不打断余额展示
                    AddRefreshErrorHint(stack, spec.ErrorMessage);
                }
            }

            card.Child = stack;
            return card;
        }

        /// <summary>刷新失败且无数据可显时的整行提示：错误信息 + 「重试」按钮（区别于「未配置 → 去配置」）</summary>
        private void AddRefreshErrorRow(StackPanel stack, string? message)
        {
            var i18n = LocalizationManager.Instance;
            var dock = new DockPanel { Margin = new Thickness(0, 8, 0, 2) };

            var btnRetry = new Button
            {
                Content = i18n.Retry,
                Padding = new Thickness(8, 2, 8, 2),
                FontSize = 11,
                Background = new SolidColorBrush(Color.FromRgb(37, 99, 235)),
                Foreground = Brushes.White,
                Cursor = System.Windows.Input.Cursors.Hand,
                HorizontalAlignment = HorizontalAlignment.Right
            };
            // async void 事件回调的异常会逃出到 Dispatcher（被 App 层吞掉），这里兜底记录便于排查
            btnRetry.Click += async (s, e) =>
            {
                try
                {
                    await RefreshManager.Instance.RefreshAllAsync(RefreshTrigger.Manual);
                }
                catch (Exception ex)
                {
                    Log.Error("popover", $"重试按钮手动刷新异常: {ex}");
                }
            };
            DockPanel.SetDock(btnRetry, Dock.Right);
            dock.Children.Add(btnRetry);

            var msgBlock = new TextBlock
            {
                Text = message ?? i18n.RefreshErrorHint,
                FontSize = 11,
                // 橙色：瞬时刷新失败；红色保留给「未配置」
                Foreground = new SolidColorBrush(Color.FromRgb(234, 88, 12)),
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center
            };
            dock.Children.Add(msgBlock);
            stack.Children.Add(dock);
        }

        /// <summary>已授权、旧数据保留展示、本轮刷新失败时，卡片末尾的小字提示</summary>
        private void AddRefreshErrorHint(StackPanel stack, string? message)
        {
            stack.Children.Add(new TextBlock
            {
                Text = message ?? LocalizationManager.Instance.RefreshErrorHint,
                FontSize = 10,
                Foreground = new SolidColorBrush(Color.FromRgb(234, 88, 12)),
                TextTrimming = TextTrimming.CharacterEllipsis,
                Margin = new Thickness(0, 4, 0, 0)
            });
        }

        /// <summary>数据读自厂商客户端本地缓存时，卡片末尾的来源与缓存时间小字（与刷新失败提示同款，灰色）</summary>
        private void AddCacheNote(StackPanel stack, string note)
        {
            stack.Children.Add(new TextBlock
            {
                Text = note,
                FontSize = 10,
                Foreground = new SolidColorBrush(Color.FromRgb(107, 114, 128)),
                TextTrimming = TextTrimming.CharacterEllipsis,
                Margin = new Thickness(0, 4, 0, 0)
            });
        }

        private UIElement CreateWindowQuotaRow(TokenWindow window, string badgeText)
        {
            var isBalance = window.Kind == TokenWindowKind.Balance;
            var isStatus = window.Kind == TokenWindowKind.Status;
            if (isBalance)
            {
                badgeText = LocalizationManager.Instance.BalanceBadge;
            }
            else
            {
                // 角标按窗口标题的周期语义推断：月度额度显示「每月」而不是槽位默认的「每周」
                badgeText = window.BadgeLabel(badgeText);
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

            if (isStatus)
            {
                // 状态型窗口：没有真实额度，只放一个绿色状态点，不显示「剩余 x%」
                var dot = new Ellipse
                {
                    Width = 7,
                    Height = 7,
                    Fill = window.StatusBrush(),
                    VerticalAlignment = VerticalAlignment.Center,
                    Margin = new Thickness(6, 0, 2, 0)
                };
                Grid.SetColumn(dot, 2);
                topGrid.Children.Add(dot);
            }
            else if (isBalance)
            {
                // 余额窗口：直接显示金额，而不是"剩余 X%"
                var balanceBlock = new TextBlock
                {
                    Text = window.BalanceFormatted,
                    FontSize = 13,
                    FontWeight = FontWeights.Bold,
                    Foreground = window.StatusBrush(),
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
                    Foreground = window.StatusBrush(),
                    VerticalAlignment = VerticalAlignment.Bottom
                });
                Grid.SetColumn(pctStack, 2);
                topGrid.Children.Add(pctStack);
            }

            rowStack.Children.Add(topGrid);

            if (isStatus)
            {
                // 状态型窗口到此为止：没有进度条、时间范围与倒计时
                return rowStack;
            }

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
                Background = window.StatusBrush(),
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
            // 悬停预览时不能抢焦点，否则会打断用户当前的操作
            ShowActivated = activate;

            // 第一次定位用上次布局的尺寸（首次显示时 ActualHeight 为 0，会用估计高度），
            // 避免窗口先在错误位置闪一下
            PositionNearTray();
            Show();
            if (activate)
            {
                Activate();
            }

            // SizeToContent=Height 的窗口要等布局跑完 ActualHeight 才可信：
            // 内容变多/变少时都用真实高度再定位一次，否则底部会被任务栏盖住或留出大片空白
            Dispatcher.InvokeAsync(PositionNearTray, DispatcherPriority.Loaded);
        }

        /// <summary>
        /// 把窗口固定在托盘所在屏幕工作区贴近任务栏的角落：任务栏在底部/右侧时贴右下角，
        /// 在顶部时贴右上角，在左侧时贴左下角（即系统通知弹窗的位置）。
        /// 不跟随光标定位——托盘图标（尤其是折叠进溢出区的图标）会被浮窗盖住。
        /// 以光标所在屏幕为准（托盘只会在被点击/悬停的那块屏上）；
        /// Screen 给的是物理像素，WPF 的 Left/Top 是逻辑像素，需要按 DPI 换算。
        /// </summary>
        private void PositionNearTray()
        {
            System.Drawing.Point cursor;
            System.Windows.Forms.Screen screen;
            try
            {
                cursor = System.Windows.Forms.Cursor.Position;
                screen = System.Windows.Forms.Screen.FromPoint(cursor);
            }
            catch (Exception ex)
            {
                Log.Warn("ui", $"读取屏幕信息失败，退回主屏工作区: {ex.Message}");
                var wa = SystemParameters.WorkArea;
                Left = wa.Right - (ActualWidth > 0 ? ActualWidth : Width) - 10;
                Top = wa.Bottom - (ActualHeight > 0 ? ActualHeight : 400) - 10;
                return;
            }

            var work = screen.WorkingArea;
            var bounds = screen.Bounds;

            // 物理像素 → 逻辑像素的缩放系数
            double scaleX = 1.0, scaleY = 1.0;
            var source = PresentationSource.FromVisual(this);
            if (source?.CompositionTarget != null)
            {
                var m = source.CompositionTarget.TransformFromDevice;
                scaleX = m.M11;
                scaleY = m.M22;
            }
            else
            {
                var dpi = VisualTreeHelper.GetDpi(this);
                if (dpi.DpiScaleX > 0) scaleX = 1.0 / dpi.DpiScaleX;
                if (dpi.DpiScaleY > 0) scaleY = 1.0 / dpi.DpiScaleY;
            }

            double w = ActualWidth > 0 ? ActualWidth : (double.IsNaN(Width) ? 330 : Width);
            double h = ActualHeight > 0 ? ActualHeight : (double.IsNaN(Height) ? 400 : Height);

            double waLeft = work.Left * scaleX;
            double waTop = work.Top * scaleY;
            double waRight = work.Right * scaleX;
            double waBottom = work.Bottom * scaleY;
            const double margin = 10;

            double left = waRight - w - margin;
            double top = waBottom - h - margin;
            if (work.Left > bounds.Left)
            {
                // 任务栏在左侧：托盘在左下角，窗口贴工作区左下角
                left = waLeft + margin;
            }
            else if (work.Top > bounds.Top)
            {
                // 任务栏在顶部：托盘在右上角，窗口贴工作区右上角
                top = waTop + margin;
            }

            // 钳制在工作区内，避免超出屏幕边缘
            left = Math.Max(waLeft + margin, Math.Min(left, waRight - w - margin));
            top = Math.Max(waTop + margin, Math.Min(top, waBottom - h - margin));

            Left = left;
            Top = top;
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
