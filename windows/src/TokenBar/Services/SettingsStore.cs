using System;
using System.IO;
using System.Text.Json;
using TokenBar.Models;

namespace TokenBar.Services
{
    /// <summary>
    /// settings.json 的加载与原子写。从 RefreshManager 原样提取：
    /// 路径计算、损坏文件改名保留、临时文件 + Move 的原子替换、_saveLock 串行化，
    /// 以及全部日志文案，都与原实现逐字节一致。
    ///
    /// 只负责磁盘 I/O；语言应用、定时器重建、凭据同步等后续动作仍由 RefreshManager 编排。
    /// </summary>
    internal sealed class SettingsStore
    {
        private readonly string _configFilePath;
        private readonly object _saveLock = new();

        public SettingsStore()
        {
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            var folder = Path.Combine(appData, "TokenBar");
            Directory.CreateDirectory(folder);
            _configFilePath = Path.Combine(folder, "settings.json");
        }

        /// <summary>
        /// 读取 settings.json。文件不存在或反序列化出 null 时返回 <paramref name="fallback"/>
        /// （等价于原实现「Settings 保持不动」）；读取抛异常时返回全新的 AppSettings，
        /// 并把损坏文件改名保留现场，用户还能从里面把 API Key 抄回来。
        /// </summary>
        public AppSettings Load(AppSettings fallback)
        {
            try
            {
                if (File.Exists(_configFilePath))
                {
                    var json = File.ReadAllText(_configFilePath);
                    var loaded = JsonSerializer.Deserialize<AppSettings>(json);
                    if (loaded != null) return loaded;
                }
            }
            catch (Exception ex)
            {
                // 读坏了的配置不能原地覆盖：改名保留现场，用户还能从里面把 API Key 抄回来
                Log.Error("settings", $"settings.json 读取失败，已改名保留: {ex.Message}");
                try
                {
                    var corrupt = _configFilePath + ".corrupt-" + DateTime.Now.ToString("yyyyMMddHHmmss");
                    File.Move(_configFilePath, corrupt, overwrite: true);
                    Log.Error("settings", $"损坏文件已改名为 {Path.GetFileName(corrupt)}");
                }
                catch (Exception moveEx)
                {
                    Log.Error("settings", $"改名损坏的 settings.json 失败: {moveEx.Message}");
                }
                return new AppSettings();
            }

            return fallback;
        }

        /// <summary>只写 settings.json（凭证字段是否落盘由 Settings.SecretsInKeychain 决定），不碰凭据管理器</summary>
        public void Save(AppSettings settings)
        {
            try
            {
                // SerializeForDisk 在 SecretsInKeychain 时序列化的是去掉凭证的副本，内存对象保持明文
                var json = settings.SerializeForDisk();
                // 先写临时文件再原子替换：进程在写到一半时被杀，不会留下半截 JSON
                lock (_saveLock)
                {
                    var tmp = _configFilePath + ".tmp";
                    File.WriteAllText(tmp, json);
                    File.Move(tmp, _configFilePath, overwrite: true);
                }
            }
            catch (Exception ex)
            {
                Log.Error("settings", $"settings.json 写入失败: {ex.Message}");
            }
        }
    }
}
