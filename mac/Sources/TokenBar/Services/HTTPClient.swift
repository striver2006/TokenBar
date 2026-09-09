import Foundation

/// 全局 HTTP 出口。所有额度查询必须走这里，不要再用 `URLSession.shared`。
///
/// 换掉 shared 的两个理由，都是线上真实故障：
///
/// 1. `URLSession.shared` 的 `timeoutIntervalForResource` 默认是 **7 天**。
///    `URLRequest.timeoutInterval` 只是"不活动超时"——连接已建立、服务端慢速滴流
///    数据时它可能一直不触发。在代理（fake-ip）环境下 TCP 停在 ESTABLISHED 而
///    响应永不完成，请求就能挂到天荒地老，把 RefreshManager 的刷新闸门占死。
/// 2. shared 自带磁盘 + 内存 URLCache 且默认 `useProtocolCachePolicy`。本项目有
///    一批厂商（OpenAI / Anthropic / DeepSeek / KIMI / 火山 / GLM / OpenRouter /
///    自定义）的额度是从 **响应头** 里取的，一旦命中缓存会连响应头一起回放旧值，
///    而 UI 上的 lastUpdated 照样往前走。
public enum HTTPClient {

    /// 单请求不活动超时的默认上限（秒）
    public static let defaultRequestTimeout: TimeInterval = 12
    /// 单请求端到端硬上限（秒）。URLRequest 没有对应字段，只能配在 session 上。
    public static let resourceTimeout: TimeInterval = 30

    public static let session: URLSession = {
        // ephemeral：无磁盘缓存、无持久 Cookie 罐、无凭证缓存。
        // 本项目所有 Cookie（百炼控制台、小米 MiMo）都是从设置里读出来手动塞进
        // header 的，没有任何地方依赖 URLSession 的 Cookie 罐，所以是安全的。
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = defaultRequestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.waitsForConnectivity = false
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpMaximumConnectionsPerHost = 4
        config.httpAdditionalHeaders = ["Cache-Control": "no-cache"]
        // connectionProxyDictionary 保持默认，继续继承系统代理设置。
        return URLSession(configuration: config)
    }()

    /// 与 `URLSession.data(for:)` 完全同形，调用点可直接替换。
    ///
    /// 各 Service 已显式设的 5/10/12s 超时保留原值；没设过的（默认 60s）和
    /// 超过上限的一律压到 `defaultRequestTimeout`。
    public static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var req = request
        if req.timeoutInterval <= 0 || req.timeoutInterval > defaultRequestTimeout {
            req.timeoutInterval = defaultRequestTimeout
        }
        req.cachePolicy = .reloadIgnoringLocalCacheData
        return try await session.data(for: req)
    }
}
