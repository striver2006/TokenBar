import Foundation
import CryptoKit

/// 阿里云 OpenAPI V3 签名（ACS3-HMAC-SHA256）。
///
/// 与官方百炼 CLI (bailian-cli-core) 内部的 `Pt()` 实现逐行对齐，供以下接口复用：
/// - `GenerateCLIAccessToken`：用长期 AccessKey 换控制台 access_token，
///   不经过浏览器、不受控制台单点登录 (SSO) 多设备互踢限制；
/// - `QueryAccountBalance`：查询阿里云账户现金余额。
///
/// 注意：`content-type` 恒为 `application/json` 且**参与签名**，即使 body 为空。
/// 实际发出的请求头必须与此逐字节一致（不能带 `; charset=utf-8`），否则服务端
/// 重算签名会得到 `SignatureDoesNotMatch`。
public enum AliyunSigner {
    public static let algorithm = "ACS3-HMAC-SHA256"

    /// 空 body 的 SHA256，`GenerateCLIAccessToken` 这类无参接口会用到。
    public static let emptyBodySHA256 =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    // MARK: - 对外入口

    /// 生成签好名的请求头（含 `authorization`）。
    ///
    /// - Parameters:
    ///   - host: 接口域名，不带协议，例如 `modelstudio.cn-beijing.aliyuncs.com`
    ///   - pathname: 请求路径，RPC 风格接口固定为 `/`
    ///   - queryString: 已规范化的 canonical query string（用 `canonicalQueryString(_:)` 生成），无参数传空串
    ///   - body: 请求体，无 body 传空 `Data`
    ///   - date / nonce: 仅供单元测试注入固定值，业务调用不要传
    public static func signedHeaders(
        host: String,
        pathname: String = "/",
        method: String = "POST",
        action: String,
        version: String,
        queryString: String = "",
        body: Data = Data(),
        accessKeyId: String,
        accessKeySecret: String,
        securityToken: String? = nil,
        date: Date = Date(),
        nonce: String = UUID().uuidString
    ) -> [String: String] {
        let contentSha256 = hexSHA256(body)
        var headers = canonicalHeaderMap(
            host: host,
            action: action,
            version: version,
            date: date,
            nonce: nonce,
            contentSha256: contentSha256,
            securityToken: securityToken
        )
        let signedHeaderList = signedHeaderList(headers)
        let request = canonicalRequest(
            method: method,
            pathname: pathname,
            queryString: queryString,
            headerMap: headers,
            contentSha256: contentSha256
        )
        let signature = hexHMACSHA256(key: accessKeySecret, message: stringToSign(request))

        headers["authorization"] =
            "\(algorithm) Credential=\(accessKeyId),SignedHeaders=\(signedHeaderList),Signature=\(signature)"
        return headers
    }

    // MARK: - 中间产物（单独暴露便于单测断言）

    /// 参与签名的 header 固定集合：`host`、`content-type` 与全部 `x-acs-*`。
    static func canonicalHeaderMap(
        host: String,
        action: String,
        version: String,
        date: Date,
        nonce: String,
        contentSha256: String,
        securityToken: String?
    ) -> [String: String] {
        var headers: [String: String] = [
            "host": host,
            "content-type": "application/json",
            "x-acs-action": action,
            "x-acs-version": version,
            "x-acs-date": iso8601Seconds(date),
            "x-acs-signature-nonce": nonce,
            "x-acs-content-sha256": contentSha256
        ]
        if let securityToken, !securityToken.isEmpty {
            headers["x-acs-security-token"] = securityToken
        }
        return headers
    }

    /// 按 key 升序拼成 `a;b;c`。
    static func signedHeaderList(_ headerMap: [String: String]) -> String {
        signedKeys(headerMap).joined(separator: ";")
    }

    static func canonicalRequest(
        method: String,
        pathname: String,
        queryString: String,
        headerMap: [String: String],
        contentSha256: String
    ) -> String {
        let keys = signedKeys(headerMap)
        // 每行一个 header，整体以换行结尾 —— 于是 canonicalRequest 中会出现一个空行
        let canonicalHeaders = keys.map { "\($0):\(headerMap[$0] ?? "")" }.joined(separator: "\n") + "\n"
        return [
            method,
            pathname,
            queryString,
            canonicalHeaders,
            keys.joined(separator: ";"),
            contentSha256
        ].joined(separator: "\n")
    }

    static func stringToSign(_ canonicalRequest: String) -> String {
        "\(algorithm)\n\(hexSHA256(Data(canonicalRequest.utf8)))"
    }

    private static func signedKeys(_ headerMap: [String: String]) -> [String] {
        headerMap.keys
            .filter { $0 == "host" || $0 == "content-type" || $0.hasPrefix("x-acs-") }
            .sorted()
    }

    // MARK: - 编码与摘要

    /// 把查询参数拼成 canonical query string：key 升序、键值均按 RFC3986 编码、空值参数丢弃。
    public static func canonicalQueryString(_ params: [String: String]) -> String {
        params
            .filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")
    }

    /// RFC3986 编码：只保留 `A-Z a-z 0-9 - _ . ~`，其余一律转义为大写 `%XX`。
    /// 等价于 JS 的 `encodeURIComponent` 后再额外转义 `!'()*`。
    public static func percentEncode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// `x-acs-date` 要求 ISO8601 秒精度并以 Z 结尾，例如 `2024-01-01T00:00:00Z`。
    /// 必须固定 en_US_POSIX + UTC，否则在中文/佛历等 locale 下会产出非 ISO 文本导致签名失败。
    public static func iso8601Seconds(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }

    public static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hexHMACSHA256(key: String, message: String) -> String {
        HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: Data(key.utf8))
        ).map { String(format: "%02x", $0) }.joined()
    }
}
