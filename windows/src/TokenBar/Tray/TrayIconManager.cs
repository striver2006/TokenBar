using System;
using System.Drawing;
using System.IO;
using System.Reflection;
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
        private ContextMenuStrip? _contextMenu;
        private PopoverWindow? _popoverWindow;
        private SettingsWindow? _settingsWindow;
        private Icon? _customIcon;
        // Icon.FromHandle 不拥有句柄，GetHicon 出来的 HICON 必须由我们 DestroyIcon
        private IntPtr _generatedIconHandle = IntPtr.Zero;

        // 托盘悬停显示额度卡片（行为对齐 macOS 端：停留后显示，移开后隐藏，点击打开视为钉住）
        private System.Windows.Forms.Timer? _hoverTimer;
        private DateTime _hoverEnterUtc = DateTime.MinValue;
        private DateTime _hoverLeftUtc = DateTime.MinValue;
        private DateTime _lastTrayMoveUtc = DateTime.MinValue;
        private Point _lastTrayCursorPos;
        private bool _hoverPopoverShown;

        private const int HoverEnterDelayMs = 150;
        private const int HoverExitDelayMs = 350;
        private const int HoverPollMs = 50;
        private const int HoverTolerancePx = 32;
        /// <summary>NotifyIcon.Text 的 Win32 上限（NOTIFYICONDATA.szTip 为 128 字符，WinForms 限制 63）。</summary>
        private const int MaxTrayTextLength = 63;

        [StructLayout(LayoutKind.Sequential)]
        private struct Win32Rect
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;

            public bool Contains(Point p) => p.X >= Left && p.X <= Right && p.Y >= Top && p.Y <= Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct NotifyIconIdentifier
        {
            public uint cbSize;
            public IntPtr hWnd;
            public uint uID;
            public Guid guidItem;
        }

        [DllImport("user32.dll")]
        private static extern bool GetWindowRect(IntPtr hWnd, out Win32Rect lpRect);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DestroyIcon(IntPtr hIcon);

        [DllImport("shell32.dll", SetLastError = true)]
        private static extern int Shell_NotifyIconGetRect(ref NotifyIconIdentifier identifier, out Win32Rect iconLocation);

        // 反射拿到的 NotifyIcon 内部 hWnd / uID；拿不到时为 null，回退到「鼠标停止移动 + 容差」判据
        private (IntPtr HWnd, uint Id)? _trayIdentity;
        private bool _trayIdentityResolved;

        public TrayIconManager()
        {
            Instance = this;
        }

        public void Initialize()
        {
            _customIcon = LoadOrGenerateIcon();

            _notifyIcon = new NotifyIcon
            {
                Text = TrayText(),
                Icon = _customIcon,
                Visible = true
            };

            BuildContextMenu();

            LocalizationManager.Instance.PropertyChanged += OnLanguageChanged;

            _notifyIcon.MouseClick += OnNotifyIconMouseClick;
            _notifyIcon.MouseMove += OnNotifyIconMouseMove;
            _notifyIcon.DoubleClick += OnNotifyIconDoubleClick;
            _notifyIcon.BalloonTipClicked += OnBalloonTipClicked;

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
            catch (Exception ex)
            {
                Log.Warn("tray", $"启动气泡显示失败: {ex.Message}");
            }
        }

        private static string TrayText()
        {
            var text = $"{LocalizationManager.Instance.AppName} - {LocalizationManager.Instance.Subtitle}";
            // 超长会让 NotifyIcon 的 Text setter 直接抛 ArgumentOutOfRangeException
            return text.Length > MaxTrayTextLength ? text.Substring(0, MaxTrayTextLength) : text;
        }

        private void OnLanguageChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
        {
            if (_notifyIcon == null) return;
            _notifyIcon.Text = TrayText();
            BuildContextMenu();
        }

        private void OnNotifyIconMouseClick(object? sender, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left)
            {
                TogglePopover();
            }
        }

        private void OnNotifyIconDoubleClick(object? sender, EventArgs e) => TogglePopover();

        private void OnBalloonTipClicked(object? sender, EventArgs e) => TogglePopover();

        private Icon LoadOrGenerateIcon()
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
            catch (Exception ex)
            {
                Log.Warn("tray", $"提取 exe 图标失败，改用内置图标: {ex.Message}");
            }

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

                // Icon.FromHandle 返回的 Icon 不拥有该 HICON，Dispose 不会释放它，记下来退出时 DestroyIcon
                _generatedIconHandle = bmp.GetHicon();
                return Icon.FromHandle(_generatedIconHandle);
            }
            catch (Exception ex)
            {
                Log.Warn("tray", $"生成内置图标失败，改用系统图标: {ex.Message}");
                return SystemIcons.Application;
            }
        }

        private void BuildContextMenu()
        {
            if (_notifyIcon == null) return;

            var contextMenu = new ContextMenuStrip();

            var titleItem = new ToolStripMenuItem(TrayText())
            {
                Enabled = false
            };
            contextMenu.Items.Add(titleItem);
            contextMenu.Items.Add(new ToolStripSeparator());

            var refreshItem = new ToolStripMenuItem(LocalizationManager.Instance.RefreshAll, null, async (s, e) =>
            {
                await RefreshManager.Instance.RefreshAllAsync(RefreshTrigger.Manual);
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

            // 语言切换会重建菜单：旧的 ContextMenuStrip 是 Win32 资源，不 Dispose 会随每次切换泄漏
            var old = _contextMenu;
            _contextMenu = contextMenu;
            _notifyIcon.ContextMenuStrip = contextMenu;
            old?.Dispose();
        }

        // ---------- 悬停 ----------

        private void OnNotifyIconMouseMove(object? sender, MouseEventArgs e)
        {
            var now = DateTime.UtcNow;
            _lastTrayMoveUtc = now;
            _lastTrayCursorPos = Cursor.Position;

            // 关掉悬停预览时不启动轮询定时器，避免无意义的 50ms tick
            if (!RefreshManager.Instance.Settings.EnableHover) return;

            if (_hoverTimer == null)
            {
                _hoverTimer = new System.Windows.Forms.Timer { Interval = HoverPollMs };
                _hoverTimer.Tick += HoverTimer_Tick;
            }
            if (!_hoverTimer.Enabled)
            {
                _hoverEnterUtc = now;
                _hoverTimer.Start();
            }
        }

        private void HoverTimer_Tick(object? sender, EventArgs e)
        {
            if (_notifyIcon == null || _hoverTimer == null) return;

            if (!RefreshManager.Instance.Settings.EnableHover)
            {
                _hoverTimer.Stop();
                return;
            }

            var now = DateTime.UtcNow;
            var cursor = Cursor.Position;
            var overTray = IsCursorOverTrayIcon(cursor);

            if (!_hoverPopoverShown)
            {
                if (!overTray)
                {
                    // 还没停够就离开了：重置计时
                    _hoverTimer.Stop();
                    return;
                }

                if ((now - _hoverEnterUtc).TotalMilliseconds < HoverEnterDelayMs) return;

                var popover = EnsurePopover();
                if (!popover.IsVisible)
                {
                    _hoverPopoverShown = true;
                    _hoverLeftUtc = DateTime.MinValue;
                    popover.ShowNearTray(activate: false);
                }
                else
                {
                    // 已通过点击打开（钉住），悬停逻辑不再接管
                    _hoverTimer.Stop();
                }
                return;
            }

            // 已经因悬停显示：光标在托盘图标或卡片上就保持；都不在且持续超过退出延迟才隐藏
            if (overTray || IsCursorOverPopover(cursor))
            {
                _hoverLeftUtc = DateTime.MinValue;
                return;
            }

            if (_hoverLeftUtc == DateTime.MinValue)
            {
                _hoverLeftUtc = now;
                return;
            }

            if ((now - _hoverLeftUtc).TotalMilliseconds >= HoverExitDelayMs)
            {
                _popoverWindow?.Hide();
                _hoverPopoverShown = false;
                _hoverTimer.Stop();
            }
        }

        /// <summary>
        /// 光标是否在托盘图标矩形内。优先用 Shell_NotifyIconGetRect 取真实矩形；
        /// 反射拿不到 NotifyIcon 的 hWnd/uID 时回退到「最近一次 MouseMove 的位置 + 容差」。
        /// </summary>
        private bool IsCursorOverTrayIcon(Point cursor)
        {
            var identity = ResolveTrayIdentity();
            if (identity.HasValue)
            {
                var id = new NotifyIconIdentifier
                {
                    cbSize = (uint)Marshal.SizeOf<NotifyIconIdentifier>(),
                    hWnd = identity.Value.HWnd,
                    uID = identity.Value.Id,
                    guidItem = Guid.Empty
                };
                try
                {
                    var hr = Shell_NotifyIconGetRect(ref id, out var rect);
                    if (hr == 0)
                    {
                        return rect.Contains(cursor);
                    }
                    Log.Debug("tray", $"Shell_NotifyIconGetRect 失败 hr=0x{hr:X8}，回退容差判据");
                }
                catch (Exception ex)
                {
                    Log.Debug("tray", $"Shell_NotifyIconGetRect 异常，回退容差判据: {ex.Message}");
                }
                // 本次失败后不再重试 API，避免每 50ms 打一次日志
                _trayIdentity = null;
            }

            // 回退：NotifyIcon 只在光标在图标上时才上报 MouseMove。
            // 最近仍有 MouseMove，或光标离上次上报位置很近，都视为仍在图标上。
            var idleMs = (DateTime.UtcNow - _lastTrayMoveUtc).TotalMilliseconds;
            if (idleMs <= HoverPollMs * 3) return true;
            return Math.Abs(cursor.X - _lastTrayCursorPos.X) <= HoverTolerancePx
                && Math.Abs(cursor.Y - _lastTrayCursorPos.Y) <= HoverTolerancePx;
        }

        /// <summary>
        /// 通过反射取 NotifyIcon 的私有字段：.NET 5+ 为 _window / _id，.NET Framework 为 window / id。
        /// 只解析一次；失败时返回 null 并永久回退。
        /// </summary>
        private (IntPtr HWnd, uint Id)? ResolveTrayIdentity()
        {
            if (_trayIdentityResolved) return _trayIdentity;
            _trayIdentityResolved = true;

            if (_notifyIcon == null) return null;
            try
            {
                var type = typeof(NotifyIcon);
                const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
                var windowField = type.GetField("_window", flags) ?? type.GetField("window", flags);
                var idField = type.GetField("_id", flags) ?? type.GetField("id", flags);
                if (windowField == null || idField == null)
                {
                    Log.Notice("tray", "NotifyIcon 内部字段名不匹配，悬停判据回退到容差模式");
                    return null;
                }

                var window = windowField.GetValue(_notifyIcon) as NativeWindow;
                var idValue = idField.GetValue(_notifyIcon);
                if (window == null || idValue == null)
                {
                    return null;
                }
                var handle = window.Handle;
                if (handle == IntPtr.Zero)
                {
                    // 句柄要等 NotifyIcon 首次显示后才创建；下次再解析
                    _trayIdentityResolved = false;
                    return null;
                }
                var uid = Convert.ToUInt32(idValue);
                _trayIdentity = (handle, uid);
                return _trayIdentity;
            }
            catch (Exception ex)
            {
                Log.Notice("tray", $"反射读取 NotifyIcon 内部字段失败，悬停判据回退到容差模式: {ex.Message}");
                return null;
            }
        }

        private bool IsCursorOverPopover(Point cursor)
        {
            if (_popoverWindow == null || !_popoverWindow.IsVisible) return false;
            var hwnd = new System.Windows.Interop.WindowInteropHelper(_popoverWindow).Handle;
            if (hwnd == IntPtr.Zero) return false;
            if (!GetWindowRect(hwnd, out var rect)) return false;
            return rect.Contains(cursor);
        }

        // ---------- 窗口单实例 ----------

        /// <summary>浮窗单实例：Closing 被拦成 Hide，所以只在第一次或已被 ForceClose 后才新建。</summary>
        private PopoverWindow EnsurePopover()
        {
            if (_popoverWindow == null)
            {
                _popoverWindow = new PopoverWindow();
                _popoverWindow.Closed += OnPopoverClosed;
            }
            return _popoverWindow;
        }

        private void OnPopoverClosed(object? sender, EventArgs e)
        {
            if (sender is PopoverWindow w) w.Closed -= OnPopoverClosed;
            if (ReferenceEquals(sender, _popoverWindow)) _popoverWindow = null;
        }

        public void TogglePopover()
        {
            var popover = EnsurePopover();

            // 点击打开的浮窗视为“钉住”，悬停自动隐藏逻辑退出
            _hoverPopoverShown = false;
            _hoverTimer?.Stop();

            if (popover.IsVisible)
            {
                popover.Hide();
            }
            else
            {
                popover.ShowNearTray();
            }
        }

        /// <summary>第二实例启动时激活首实例:显示浮窗(已显示则仅置前),不切换。</summary>
        public void ShowPopover()
        {
            var popover = EnsurePopover();

            // 与 TogglePopover 相同的“钉住”语义:停掉悬停自动隐藏
            _hoverPopoverShown = false;
            _hoverTimer?.Stop();

            if (popover.IsVisible)
            {
                popover.Activate();
            }
            else
            {
                popover.ShowNearTray();
            }
        }

        public void OpenSettings(SettingsTab tab = SettingsTab.General)
        {
            if (_settingsWindow == null)
            {
                _settingsWindow = new SettingsWindow(tab);
                _settingsWindow.Closed += OnSettingsClosed;
            }
            else
            {
                _settingsWindow.SelectTab(tab);
            }

            _settingsWindow.Show();
            if (_settingsWindow.WindowState == System.Windows.WindowState.Minimized)
            {
                _settingsWindow.WindowState = System.Windows.WindowState.Normal;
            }
            _settingsWindow.Activate();
        }

        private void OnSettingsClosed(object? sender, EventArgs e)
        {
            if (sender is SettingsWindow w) w.Closed -= OnSettingsClosed;
            if (ReferenceEquals(sender, _settingsWindow)) _settingsWindow = null;
        }

        /// <summary>托盘气泡提醒（余额不足等），点击气泡会打开额度浮窗。</summary>
        public void ShowBalloon(string title, string message)
        {
            try
            {
                _notifyIcon?.ShowBalloonTip(5000, title, message, ToolTipIcon.Warning);
            }
            catch (Exception ex)
            {
                Log.Warn("tray", $"气泡提醒显示失败: {ex.Message}");
            }
        }

        public void Dispose()
        {
            LocalizationManager.Instance.PropertyChanged -= OnLanguageChanged;

            if (_hoverTimer != null)
            {
                _hoverTimer.Stop();
                _hoverTimer.Tick -= HoverTimer_Tick;
                _hoverTimer.Dispose();
                _hoverTimer = null;
            }

            if (_notifyIcon != null)
            {
                _notifyIcon.MouseClick -= OnNotifyIconMouseClick;
                _notifyIcon.MouseMove -= OnNotifyIconMouseMove;
                _notifyIcon.DoubleClick -= OnNotifyIconDoubleClick;
                _notifyIcon.BalloonTipClicked -= OnBalloonTipClicked;
                _notifyIcon.Visible = false;
                _notifyIcon.Dispose();
                _notifyIcon = null;
            }

            _contextMenu?.Dispose();
            _contextMenu = null;

            _popoverWindow?.ForceClose();
            _settingsWindow?.Close();

            if (_customIcon != null && !ReferenceEquals(_customIcon, SystemIcons.Application))
            {
                _customIcon.Dispose();
            }
            _customIcon = null;

            if (_generatedIconHandle != IntPtr.Zero)
            {
                DestroyIcon(_generatedIconHandle);
                _generatedIconHandle = IntPtr.Zero;
            }

            if (ReferenceEquals(Instance, this)) Instance = null;
        }
    }
}
