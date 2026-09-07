using System;
using System.IO;
using System.Windows;
using Application = System.Windows.Application;
using TokenBar.Services;
using TokenBar.Tray;

namespace TokenBar
{
    public partial class App : Application
    {
        private TrayIconManager? _trayManager;

        public App()
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;

            AppDomain.CurrentDomain.UnhandledException += (s, e) =>
            {
                Log($"Unhandled AppDomain Exception: {e.ExceptionObject}");
            };

            DispatcherUnhandledException += (s, e) =>
            {
                Log($"Unhandled Dispatcher Exception: {e.Exception}");
                e.Handled = true;
            };
        }

        protected override void OnStartup(StartupEventArgs e)
        {
            Log("App.OnStartup enter");
            base.OnStartup(e);
            ShutdownMode = ShutdownMode.OnExplicitShutdown;

            try
            {
                // Initialize RefreshManager & load settings
                Log("Initializing RefreshManager");
                RefreshManager.Instance.Initialize();

                // Initialize System Tray Icon
                Log("Initializing TrayIconManager");
                _trayManager = new TrayIconManager();
                _trayManager.Initialize();

                // Show popover on startup so user sees the app running
                _trayManager.TogglePopover();
                Log("TokenBar startup completed successfully");
            }
            catch (Exception ex)
            {
                Log($"Error in OnStartup: {ex}");
            }
        }

        protected override void OnExit(ExitEventArgs e)
        {
            Log($"App.OnExit enter (Code: {e.ApplicationExitCode})");
            _trayManager?.Dispose();
            RefreshManager.Instance.Dispose();
            base.OnExit(e);
        }

        private static void Log(string message)
        {
            try
            {
                var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TokenBar");
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "app.log"), $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {message}\r\n");
            }
            catch { }
        }
    }
}
