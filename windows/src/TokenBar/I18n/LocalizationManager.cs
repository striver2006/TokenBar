using System;
using System.Globalization;
using TokenBar.Models;

namespace TokenBar.I18n
{
    public class LocalizationManager
    {
        public static LocalizationManager Instance { get; } = new LocalizationManager();

        public AppLanguage CurrentLanguage { get; set; } = AppLanguage.System;

        private LocalizationManager() { }

        public bool IsChinese
        {
            get
            {
                if (CurrentLanguage == AppLanguage.ZhHans) return true;
                if (CurrentLanguage == AppLanguage.En) return false;
                return CultureInfo.CurrentUICulture.TwoLetterISOLanguageName.Equals("zh", StringComparison.OrdinalIgnoreCase);
            }
        }

        public string AppName => "TokenBar";
        public string Subtitle => IsChinese ? "模型额度监控" : "Model Quota Monitor";

        public string Refresh => IsChinese ? "刷新" : "Refresh";
        public string Refreshing => IsChinese ? "刷新中" : "Refreshing...";
        public string Ready => IsChinese ? "准备就绪" : "Ready";
        public string UpdatedAt => IsChinese ? "更新于: " : "Updated: ";
        public string Settings => IsChinese ? "偏好设置..." : "Settings...";
        public string Quit => IsChinese ? "退出 TokenBar" : "Quit TokenBar";
        public string RefreshAll => IsChinese ? "立即刷新全部额度" : "Refresh All Quotas Now";

        public string FiveHourWindow => IsChinese ? "5小时" : "5-Hour";
        public string WeeklyWindow => IsChinese ? "每周" : "Weekly";
        public string Remaining => IsChinese ? "剩余" : "Left";
        public string Configure => IsChinese ? "去配置" : "Configure";
        public string NotAuthorized => IsChinese ? "尚未完成授权配置" : "Authorization required";
        public string SyncingData => IsChinese ? "正在同步额度信息..." : "Syncing quota data...";

        public string GeneralSettings => IsChinese ? "通用设置" : "General";
        public string CustomProviders => IsChinese ? "国内厂商 / 自定义" : "Custom Providers";
        public string InterfaceLanguage => IsChinese ? "界面语言 / Language" : "Language";
        public string AutoRefreshInterval => IsChinese ? "定期主动刷新周期" : "Auto-Refresh Interval";
        public string HoverPreview => IsChinese ? "鼠标悬停自动显示小提示浮窗" : "Hover Preview";
        public string LaunchAtLogin => IsChinese ? "开机自动启动" : "Launch at Login";
    }
}
