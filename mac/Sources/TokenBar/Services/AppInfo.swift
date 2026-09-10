import Foundation

/// 应用元信息。版本号只认 Info.plist 里的 `CFBundleShortVersionString`
/// （由 `Scripts/build_app.sh` 打包时写入），不在代码里另存一份手工同步的副本。
public enum AppInfo {
    public static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "dev"
    }
}
