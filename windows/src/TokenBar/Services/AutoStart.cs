using System;
using System.IO;
using Microsoft.Win32;

namespace TokenBar.Services
{
    /// <summary>
    /// 开机自启（HKCU Run 键）。
    ///
    /// Run 键只写可执行文件路径、不带任何参数：启动一律不弹浮动窗口（对齐 mac 端），
    /// 面板只在用户点按托盘图标或再次启动 TokenBar（第二实例激活）时出现。
    /// 历史版本（1.3.x~1.4.0）写入过 /boot 参数，由 <see cref="NormalizeExistingEntry"/>
    /// 在启动时清理回纯路径。
    /// </summary>
    public static class AutoStart
    {
        private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string RunValueName = "TokenBar";

        /// <summary>install.ps1 的安装目录，Run 键应指向这里而不是当前进程（可能是 bin\Debug 或临时解压目录）。</summary>
        private static string InstalledExePath => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Programs", "TokenBar", "TokenBar.exe");

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
                        key.SetValue(RunValueName, $"\"{exePath}\"");
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
        /// 1.3.x~1.4.0 期间的 Run 键带过 /boot 参数（旧语义：仅开机启动不弹浮窗，现改为一律不弹），
        /// 启动时发现即清理回纯路径。条目不存在（用户关了自启）时什么都不写。
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

                var desired = $"\"{exePath}\"";
                if (!string.Equals(current, desired, StringComparison.OrdinalIgnoreCase))
                {
                    key.SetValue(RunValueName, desired);
                    Log.Notice("settings", "开机自启条目已清理为纯路径（启动一律不弹浮窗，/boot 参数不再使用）");
                }
            }
            catch (Exception ex)
            {
                Log.Warn("settings", $"清理开机自启注册表失败: {ex.Message}");
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
