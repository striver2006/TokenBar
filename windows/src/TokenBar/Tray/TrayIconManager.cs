using System;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using TokenBar.I18n;
using TokenBar.Models;
using TokenBar.Services;
using TokenBar.Views;

namespace TokenBar.Tray
{
    public class TrayIconManager : IDisposable
    {
        public static TrayIconManager? Instance { get; private set; }

        private NotifyIcon? _notifyIcon;
        private PopoverWindow? _popoverWindow;
        private SettingsWindow? _settingsWindow;
        private Icon? _customIcon;

        // 托盘悬停显示额度卡片（行为对齐 macOS 端：停留后显示，移开后隐藏，点击打开视为钉住）
        private System.Windows.Forms.Timer? _hoverTimer;
        private DateTime _lastTrayMoveUtc = DateTime.MinValue;
        private Point _lastTrayCursorPos;
        private bool _hoverPopoverShown;

        private const int HoverEnterDelayMs = 200;
        private const int HoverExitDelayMs = 500;
        private const int HoverPollMs = 100;
        private const int HoverTolerancePx = 32;

        [StructLayout(LayoutKind.Sequential)]
        private struct Win32Rect
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [DllImport("user32.dll")]
        private static extern bool GetWindowRect(IntPtr hWnd, out Win32Rect lpRect);

        public TrayIconManager()
        {
            Instance = this;
        }

        public void Initialize()
        {
            _customIcon = LoadOrGenerateIcon();

            _notifyIcon = new NotifyIcon
            {
                Text = $"{LocalizationManager.Instance.AppName} - {LocalizationManager.Instance.Subtitle}",
                Icon = _customIcon,
                Visible = true
            };

            BuildContextMenu();

            LocalizationManager.Instance.PropertyChanged += (s, e) =>
            {
                if (_notifyIcon != null)
                {
                    _notifyIcon.Text = $"{LocalizationManager.Instance.AppName} - {LocalizationManager.Instance.Subtitle}";
                    BuildContextMenu();
                }
            };

            _notifyIcon.MouseClick += (s, e) =>
            {
                if (e.Button == MouseButtons.Left)
                {
                    TogglePopover();
                }
            };

            _notifyIcon.MouseMove += OnNotifyIconMouseMove;

            _notifyIcon.DoubleClick += (s, e) =>
            {
                TogglePopover();
            };

            _notifyIcon.BalloonTipClicked += (s, e) =>
            {
                TogglePopover();
            };

            try
            {
                _notifyIcon.ShowBalloonTip(
                    3000,
                    LocalizationManager.Instance.AppName,
                    LocalizationManager.Instance.IsChinese
                        ? "TokenBar 已在托盘运行，点击可查看模型额度"
                        : "TokenBar is running in the tray. Click to view quota.",
                    ToolTipIcon.Info);
            }
            catch { }
        }

        private static Icon LoadOrGenerateIcon()
        {
            try
            {
                var exePath = Environment.ProcessPath;
                if (!string.IsNullOrEmpty(exePath) && File.Exists(exePath))
                {
                    var extracted = Icon.ExtractAssociatedIcon(exePath);
                    if (extracted != null) return extracted;
                }
            }
            catch { }

            try
            {
                using var bmp = new Bitmap(32, 32);
                using var g = Graphics.FromImage(bmp);
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;

                using var brush = new SolidBrush(Color.FromArgb(37, 99, 235));
                g.FillEllipse(brush, 1, 1, 30, 30);

                var points = new PointF[]
                {
                    new PointF(17, 5),
                    new PointF(10, 16),
                    new PointF(16, 16),
                    new PointF(14, 27),
                    new PointF(23, 14),
                    new PointF(17, 14)
                };
                using var whiteBrush = new SolidBrush(Color.White);
                g.FillPolygon(whiteBrush, points);

                return Icon.FromHandle(bmp.GetHicon());
            }
            catch
            {
                return SystemIcons.Application;
            }
        }

        private void BuildContextMenu()
        {
            if (_notifyIcon == null) return;

            var contextMenu = new ContextMenuStrip();

            var titleItem = new ToolStripMenuItem($"{LocalizationManager.Instance.AppName} - {LocalizationManager.Instance.Subtitle}")
            {
                Enabled = false
            };
            contextMenu.Items.Add(titleItem);
            contextMenu.Items.Add(new ToolStripSeparator());

            var refreshItem = new ToolStripMenuItem(LocalizationManager.Instance.RefreshAll, null, async (s, e) =>
            {
                await RefreshManager.Instance.RefreshAllAsync();
            });
            contextMenu.Items.Add(refreshItem);

            var settingsItem = new ToolStripMenuItem(LocalizationManager.Instance.OpenSettings, null, (s, e) =>
            {
                OpenSettings(SettingsTab.General);
            });
            contextMenu.Items.Add(settingsItem);

            contextMenu.Items.Add(new ToolStripSeparator());

            var quitItem = new ToolStripMenuItem(LocalizationManager.Instance.QuitApp, null, (s, e) =>
            {
                System.Windows.Application.Current.Shutdown();
            });
            contextMenu.Items.Add(quitItem);

            _notifyIcon.ContextMenuStrip = contextMenu;
        }

        private void OnNotifyIconMouseMove(object? sender, MouseEventArgs e)
        {
            _lastTrayMoveUtc = DateTime.UtcNow;
            _lastTrayCursorPos = Cursor.Position;

            if (_hoverTimer == null)
            {
                _hoverTimer = new System.Windows.Forms.Timer { Interval = HoverPollMs };
                _hoverTimer.Tick += HoverTimer_Tick;
            }
            _hoverTimer.Start();
        }

        private void HoverTimer_Tick(object? sender, EventArgs e)
        {
            if (_notifyIcon == null || _hoverTimer == null) return;
            var idle = (DateTime.UtcNow - _lastTrayMoveUtc).TotalMilliseconds;

            if (!_hoverPopoverShown)
            {
                // 鼠标已在托盘图标上停留足够久（期间持续收到 MouseMove 或位置未变）
                if (idle >= HoverEnterDelayMs)
                {
                    if (!RefreshManager.Instance.Settings.EnableHover)
                    {
                        _hoverTimer.Stop();
                        return;
                    }

                    if (_popoverWindow == null || !_popoverWindow.IsLoaded)
                    {
                        _popoverWindow = new PopoverWindow();
                    }

                    if (!_popoverWindow.IsVisible)
                    {
                        _hoverPopoverShown = true;
                        _popoverWindow.ShowNearTray(activate: false);
                    }
                    else
                    {
                        // 已通过点击打开（钉住），悬停逻辑不再接管
                        _hoverTimer.Stop();
                    }
                }
            }
            else
            {
                // 鼠标已离开托盘图标（NotifyIcon 不再上报移动），检查是否移到了额度卡片上
                var cursor = Cursor.Position;
                var nearTray = Math.Abs(cursor.X - _lastTrayCursorPos.X) <= HoverTolerancePx
                            && Math.Abs(cursor.Y - _lastTrayCursorPos.Y) <= HoverTolerancePx;
                if (!nearTray && !IsCursorOverPopover(cursor) && idle >= HoverExitDelayMs)
                {
                    _popoverWindow?.Hide();
                    _hoverPopoverShown = false;
                    _hoverTimer.Stop();
                }
            }
        }

        private bool IsCursorOverPopover(Point cursor)
        {
            if (_popoverWindow == null || !_popoverWindow.IsVisible) return false;
            var hwnd = new System.Windows.Interop.WindowInteropHelper(_popoverWindow).Handle;
            if (hwnd == IntPtr.Zero) return false;
            if (!GetWindowRect(hwnd, out var rect)) return false;
            return cursor.X >= rect.Left && cursor.X <= rect.Right && cursor.Y >= rect.Top && cursor.Y <= rect.Bottom;
        }

        public void TogglePopover()
        {
            if (_popoverWindow == null || !_popoverWindow.IsLoaded)
            {
                _popoverWindow = new PopoverWindow();
            }

            // 点击打开的浮窗视为“钉住”，悬停自动隐藏逻辑退出
            _hoverPopoverShown = false;
            _hoverTimer?.Stop();

            if (_popoverWindow.IsVisible)
            {
                _popoverWindow.Hide();
            }
            else
            {
                _popoverWindow.ShowNearTray();
            }
        }

        /// <summary>第二实例启动时激活首实例:显示浮窗(已显示则仅置前),不切换。</summary>
        public void ShowPopover()
        {
            if (_popoverWindow == null || !_popoverWindow.IsLoaded)
            {
                _popoverWindow = new PopoverWindow();
            }

            // 与 TogglePopover 相同的“钉住”语义:停掉悬停自动隐藏
            _hoverPopoverShown = false;
            _hoverTimer?.Stop();

            if (_popoverWindow.IsVisible)
            {
                _popoverWindow.Activate();
            }
            else
            {
                _popoverWindow.ShowNearTray();
            }
        }

        public void OpenSettings(SettingsTab tab = SettingsTab.General)
        {
            if (_settingsWindow == null || !_settingsWindow.IsLoaded)
            {
                _settingsWindow = new SettingsWindow(tab);
            }
            else
            {
                _settingsWindow.SelectTab(tab);
            }

            _settingsWindow.Show();
            _settingsWindow.Activate();
        }

        /// <summary>托盘气泡提醒（余额不足等），点击气泡会打开额度浮窗。</summary>
        public void ShowBalloon(string title, string message)
        {
            try
            {
                _notifyIcon?.ShowBalloonTip(5000, title, message, ToolTipIcon.Warning);
            }
            catch { }
        }

        public void Dispose()
        {
            _hoverTimer?.Stop();
            _hoverTimer?.Dispose();
            _notifyIcon?.Dispose();
            _popoverWindow?.Close();
            _settingsWindow?.Close();
            _customIcon?.Dispose();
        }
    }
}
