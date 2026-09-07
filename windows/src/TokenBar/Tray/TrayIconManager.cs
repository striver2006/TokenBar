using System;
using System.Drawing;
using System.IO;
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

        public void TogglePopover()
        {
            if (_popoverWindow == null || !_popoverWindow.IsLoaded)
            {
                _popoverWindow = new PopoverWindow();
            }

            if (_popoverWindow.IsVisible)
            {
                _popoverWindow.Hide();
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

        public void Dispose()
        {
            _notifyIcon?.Dispose();
            _popoverWindow?.Close();
            _settingsWindow?.Close();
            _customIcon?.Dispose();
        }
    }
}
