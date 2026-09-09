using System;
using System.IO;
using System.Windows;
using Microsoft.Win32;
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

                // 睡眠期间定时器不 fire，唤醒后数据可能已经过期若干个周期
                SystemEvents.PowerModeChanged += OnPowerModeChanged;

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
            SystemEvents.PowerModeChanged -= OnPowerModeChanged;
            _trayManager?.Dispose();
            RefreshManager.Instance.Dispose();
            base.OnExit(e);
        }

        // 唤醒后补刷一次。阈值取刷新间隔的一半，短暂睡眠不会造成多余请求；
        // RefreshAllAsync 自身的闸门会吸收与定时器的重叠触发。
        private static void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
        {
            if (e.Mode != PowerModes.Resume) return;

            _ = System.Threading.Tasks.Task.Run(async () =>
            {
                try
                {
                    var half = TimeSpan.FromMinutes(
                        Math.Max(1, RefreshManager.Instance.Settings.RefreshIntervalMinutes) / 2.0);
                    await RefreshManager.Instance.RefreshIfStaleAsync(half);
                }
                catch (Exception ex)
                {
                    Log($"Refresh after resume failed: {ex}");
                }
            });
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
