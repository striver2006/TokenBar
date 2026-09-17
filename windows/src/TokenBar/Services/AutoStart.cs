using System;
using System.IO;
using Microsoft.Win32;

namespace TokenBar.Services
{
    /// <summary>
    /// 开机自启（HKCU Run 键）与「本次是否为开机启动」的判定。
    ///
    /// Run 键写成 `"exe" /boot`：系统登录时拉起的实例带 /boot 参数，启动时不再弹浮动窗口；
    /// 用户从开始菜单/快捷方式手动启动的实例没有该参数，照常弹窗示意「我在这」。
    /// 旧版写入的无参数条目由 <see cref="NormalizeExistingEntry"/> 在启动时迁移补上 /boot。
    /// </summary>
    public static class AutoStart
    {
        public const string BootArg = "/boot";

        private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string RunValueName = "TokenBar";

        /// <summary>install.ps1 的安装目录，Run 键应指向这里而不是当前进程（可能是 bin\Debug 或临时解压目录）。</summary>
        private static string InstalledExePath => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Programs", "TokenBar", "TokenBar.exe");

        /// <summary>命令行里带 /boot（或 --boot）即视为开机自启拉起。</summary>
        public static bool IsBootLaunch(string[] args)
        {
            foreach (var arg in args)
            {
                if (string.Equals(arg, BootArg, StringComparison.OrdinalIgnoreCase)
                    || string.Equals(arg, "--boot", StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
            return false;
        }

        public static bool IsConfigured()
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, false);
                return key?.GetValue(RunValueName) != null;
            }
            catch (Exception ex)
            {
                Log.Warn("settings", $"读取开机自启注册表失败: {ex.Message}");
                return false;
            }
        }

        public static void SetEnabled(bool enable)
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, true);
                if (key == null) return;

                if (enable)
                {
                    var exePath = ResolveStartupExePath();
                    if (!string.IsNullOrEmpty(exePath))
                    {
                        key.SetValue(RunValueName, $"\"{exePath}\" {BootArg}");
                    }
                }
                else
                {
                    key.DeleteValue(RunValueName, false);
                }
            }
            catch (Exception ex)
            {
                Log.Error("settings", $"写入开机自启注册表失败: {ex.Message}");
            }
        }

        /// <summary>
        /// 旧版安装留下的 Run 键不带 /boot 参数：启动时发现即补写，
        /// 否则早已开启自启的用户永远享受不到「开机不弹浮窗」。
        /// 条目不存在（用户关了自启）时什么都不写。
        /// </summary>
        public static void NormalizeExistingEntry()
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, true);
                if (key == null) return;
                if (key.GetValue(RunValueName) is not string current) return;

                var exePath = ResolveStartupExePath();
                if (string.IsNullOrEmpty(exePath)) return;

                var desired = $"\"{exePath}\" {BootArg}";
                if (!string.Equals(current, desired, StringComparison.OrdinalIgnoreCase))
                {
                    key.SetValue(RunValueName, desired);
                    Log.Notice("settings", $"开机自启条目已迁移为带 {BootArg} 参数（开机启动不弹浮窗）");
                }
            }
            catch (Exception ex)
            {
                Log.Warn("settings", $"迁移开机自启注册表失败: {ex.Message}");
            }
        }

        private static string? ResolveStartupExePath()
        {
            var processPath = Environment.ProcessPath;
            var installed = InstalledExePath;
            if (!string.IsNullOrEmpty(processPath)
                && string.Equals(Path.GetFullPath(processPath), Path.GetFullPath(installed), StringComparison.OrdinalIgnoreCase))
            {
                return installed;
            }
            if (File.Exists(installed))
            {
                Log.Notice("settings", $"当前进程不在安装目录，开机自启写入安装目录路径: {installed}");
                return installed;
            }
            if (!string.IsNullOrEmpty(processPath))
            {
                Log.Notice("settings", $"未找到安装目录下的 TokenBar.exe，开机自启写入当前进程路径: {processPath}");
                return processPath;
            }
            return null;
        }
    }
}
