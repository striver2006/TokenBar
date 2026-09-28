using System;
using System.Threading;
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

        // 单实例保护:第二实例启动时通知首实例显示浮窗后自行退出(对齐 macOS 激活已有实例的行为)
        private const string SingleInstanceMutexName = @"Local\TokenBar.SingleInstance.Mutex";
        private const string ActivateSignalName = @"Local\TokenBar.SingleInstance.Activate";
        private Mutex? _singleInstanceMutex;
        private EventWaitHandle? _activateSignal;

        // App 级日志统一走 Services/Log（%APPDATA%\TokenBar\tokenbar.log，2MB 轮转），category 固定 "app"。
        // Log 的静态构造只依赖 Environment.SpecialFolder.ApplicationData，且失败即整体降级为 no-op，
        // 在 App 构造函数里调用没有鸡生蛋问题。
        private const string LogCategory = "app";

        public App()
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;

            AppDomain.CurrentDomain.UnhandledException += (s, e) =>
            {
                Log.Error(LogCategory, $"Unhandled AppDomain Exception: {e.ExceptionObject}");
            };

            DispatcherUnhandledException += (s, e) =>
            {
                // 刻意行为：完整记录（e.Exception.ToString() 含类型、消息与 stack trace）之后吞掉异常。
                // TokenBar 是菜单栏常驻应用，一次 UI 回调异常不应该带崩整个进程；代价是异常后的
                // UI 状态可能不一致，因此必须留下日志供排查，绝不允许静默。
                Log.Error(LogCategory, $"Unhandled Dispatcher Exception: {e.Exception}");
                e.Handled = true;
            };
        }

        protected override void OnStartup(StartupEventArgs e)
        {
            Log.Info(LogCategory, "App.OnStartup enter");
            base.OnStartup(e);
            ShutdownMode = ShutdownMode.OnExplicitShutdown;

            if (!TryAcquireSingleInstance())
            {
                Log.Info(LogCategory, "Another instance is already running; activation signaled, exiting");
                Shutdown();
                return;
            }

            try
            {
                // Initialize RefreshManager & load settings
                Log.Info(LogCategory, "Initializing RefreshManager");
                RefreshManager.Instance.Initialize();

                // Initialize System Tray Icon
                Log.Info(LogCategory, "Initializing TrayIconManager");
                _trayManager = new TrayIconManager();
                _trayManager.Initialize();

                // 历史版本的 Run 键带过 /boot 参数（旧语义：仅开机启动不弹窗），
                // 现在启动一律不弹浮窗，启动时顺手把该参数清掉（条目不存在则不写）
                AutoStart.NormalizeExistingEntry();

                // 启动一律不弹浮窗（对齐 mac 端行为）：托盘图标即「我在这」，
                // 用户点按托盘图标或再次启动 TokenBar（第二实例激活）时面板才出现。

                // 睡眠期间定时器不 fire，唤醒后数据可能已经过期若干个周期
                SystemEvents.PowerModeChanged += OnPowerModeChanged;

                Log.Info(LogCategory, "TokenBar startup completed successfully");
            }
            catch (Exception ex)
            {
                Log.Error(LogCategory, $"Error in OnStartup: {ex}");
            }
        }

        protected override void OnExit(ExitEventArgs e)
        {
            Log.Info(LogCategory, $"App.OnExit enter (Code: {e.ApplicationExitCode})");
            SystemEvents.PowerModeChanged -= OnPowerModeChanged;
            _trayManager?.Dispose();
            RefreshManager.Instance.Dispose();
            _activateSignal?.Dispose();
            try { _singleInstanceMutex?.ReleaseMutex(); } catch (ApplicationException) { }
            _singleInstanceMutex?.Dispose();
            base.OnExit(e);
        }

        /// <summary>
        /// 尝试成为唯一实例。已是第二实例时,通知首实例显示浮窗并返回 false。
        /// 首实例崩溃未释放 Mutex 时,进程终止即销毁内核对象,不会造成永久锁死。
        /// </summary>
        private bool TryAcquireSingleInstance()
        {
            _singleInstanceMutex = new Mutex(initiallyOwned: true, SingleInstanceMutexName, out bool createdNew);
            if (!createdNew)
            {
                try
                {
                    if (EventWaitHandle.TryOpenExisting(ActivateSignalName, out var signal))
                    {
                        signal.Set();
                        signal.Dispose();
                    }
                }
                catch (Exception ex)
                {
                    Log.Error(LogCategory, $"Failed to signal the first instance: {ex.Message}");
                }
                return false;
            }

            // 监听后续实例的激活信号,在 UI 线程弹出浮窗
            _activateSignal = new EventWaitHandle(false, EventResetMode.AutoReset, ActivateSignalName);
            var listener = new Thread(ListenForActivation) { IsBackground = true };
            listener.Start();
            return true;
        }

        private void ListenForActivation()
        {
            while (true)
            {
                try
                {
                    _activateSignal!.WaitOne();
                }
                catch (ObjectDisposedException)
                {
                    return;
                }
                catch (Exception ex)
                {
                    Log.Error(LogCategory, $"Activation listener stopped: {ex.Message}");
                    return;
                }

                Dispatcher.BeginInvoke(() => _trayManager?.ShowPopover());
            }
        }

        // 唤醒后补刷一次。阈值取刷新间隔的一半，短暂睡眠不会造成多余请求；
        // RefreshAllAsync 自身的闸门会吸收与定时器的重叠触发。
        private static void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
        {
            if (e.Mode != PowerModes.Resume) return;

            System.Threading.Tasks.Task.Run(async () =>
            {
                try
                {
                    var half = TimeSpan.FromMinutes(
                        Math.Max(1, RefreshManager.Instance.Settings.RefreshIntervalMinutes) / 2.0);
                    await RefreshManager.Instance.RefreshIfStaleAsync(half);
                }
                catch (Exception ex)
                {
                    Log.Error(LogCategory, $"Refresh after resume failed: {ex}");
                }
            }).FireAndForget("resume-refresh");
        }
    }
}
