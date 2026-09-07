using System;
using System.Windows;
using TokenBar.Services;
using TokenBar.Tray;

namespace TokenBar
{
    public partial class App : Application
    {
        private TrayIconManager? _trayManager;

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);

            // Initialize RefreshManager & load settings
            RefreshManager.Instance.Initialize();

            // Initialize System Tray Icon
            _trayManager = new TrayIconManager();
            _trayManager.Initialize();
        }

        protected override void OnExit(ExitEventArgs e)
        {
            _trayManager?.Dispose();
            RefreshManager.Instance.Dispose();
            base.OnExit(e);
        }
    }
}
