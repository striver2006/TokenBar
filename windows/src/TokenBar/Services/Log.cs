using System;
using System.IO;
using System.Text;

namespace TokenBar.Services
{
    /// <summary>
    /// 轻量文件日志。macOS 端用 os.Logger + `log stream` 排查，Windows 没有等价物，
    /// 因此落到 %APPDATA%\TokenBar\tokenbar.log。
    ///
    /// 存在的理由：定时刷新出问题时，"定时器没触发"和"每轮都失败"这两种成因在界面上
    /// 长得一模一样，没有日志只能靠外部文件时间戳倒推，代价极大。
    ///
    /// 排查用法（PowerShell 实时跟随）：
    ///     Get-Content "$env:APPDATA\TokenBar\tokenbar.log" -Wait -Tail 50
    ///
    /// 隐私红线：绝不记录 apiKey / token / accessKeySecret / Cookie / refreshToken
    /// 及其任何片段、请求头、请求体；URL 只记 host + path，丢掉 query。
    /// </summary>
    public static class Log
    {
        private const long MaxBytes = 2 * 1024 * 1024;

        private static readonly object Gate = new();
        private static readonly string LogPath;
        private static bool _disabled;

        static Log()
        {
            try
            {
                var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
                var dir = Path.Combine(appData, "TokenBar");
                Directory.CreateDirectory(dir);
                LogPath = Path.Combine(dir, "tokenbar.log");
            }
            catch
            {
                LogPath = string.Empty;
                _disabled = true;
            }
        }

        public static void Debug(string category, string message) => Write("DEBUG", category, message);
        public static void Info(string category, string message) => Write("INFO ", category, message);
        public static void Notice(string category, string message) => Write("NOTE ", category, message);
        public static void Warn(string category, string message) => Write("WARN ", category, message);
        public static void Error(string category, string message) => Write("ERROR", category, message);

        private static void Write(string level, string category, string message)
        {
            if (_disabled) return;

            try
            {
                var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {level} [{category}] {message}{Environment.NewLine}";
                lock (Gate)
                {
                    // 超过上限就整体轮转一次，保留上一份供对比。日志绝不能把磁盘写满。
                    var info = new FileInfo(LogPath);
                    if (info.Exists && info.Length > MaxBytes)
                    {
                        var backup = LogPath + ".1";
                        if (File.Exists(backup)) File.Delete(backup);
                        File.Move(LogPath, backup);
                    }

                    File.AppendAllText(LogPath, line, Encoding.UTF8);
                }
            }
            catch
            {
                // 日志失败绝不能影响刷新本身：一次失败即永久放弃，避免每轮都抛异常。
                _disabled = true;
            }
        }
    }
}
