using System;
using System.Drawing;
using System.Windows.Forms;
using TokenBar.I18n;
using TokenBar.Services;
using TokenBar.Views;

namespace TokenBar.Tray
{
    public class TrayIconManager : IDisposable
    {
        private NotifyIcon? _notifyIcon;
        private PopoverWindow? _popoverWindow;
        private SettingsWindow? _settingsWindow;

        public void Initialize()
        {
            _notifyIcon = new NotifyIcon
            {
                Text = $"{LocalizationManager.Instance.AppName} - {LocalizationManager.Instance.Subtitle}",
                Icon = SystemIcons.Application,
                Visible = true
            };

            BuildContextMenu();

            _notifyIcon.MouseClick += (s, e) =>
            {
                if (e.Button == MouseButtons.Left)
                {
                    TogglePopover();
                }
            };
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

            var settingsItem = new ToolStripMenuItem(LocalizationManager.Instance.Settings, null, (s, e) =>
            {
                OpenSettings();
            });
            contextMenu.Items.Add(settingsItem);

            contextMenu.Items.Add(new ToolStripSeparator());

            var quitItem = new ToolStripMenuItem(LocalizationManager.Instance.Quit, null, (s, e) =>
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

        public void OpenSettings()
        {
            if (_settingsWindow == null || !_settingsWindow.IsLoaded)
            {
                _settingsWindow = new SettingsWindow();
            }
            _settingsWindow.Show();
            _settingsWindow.Activate();
        }

        public void Dispose()
        {
            _notifyIcon?.Dispose();
            _popoverWindow?.Close();
            _settingsWindow?.Close();
        }
    }
}
